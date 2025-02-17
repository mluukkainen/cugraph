/*
 * Copyright (c) 2019, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// snmg pagerank
// Author: Alex Fender afender@nvidia.com
 
#include "cub/cub.cuh"
#include <omp.h>
#include "rmm_utils.h"
#include <cugraph.h>
#include "utilities/graph_utils.cuh"
#include "snmg/utils.cuh"
#include "utilities/cusparse_helper.h"
#include "snmg/blas/spmv.cuh"
#include "snmg/link_analysis/pagerank.cuh"
#include "snmg/degree/degree.cuh"
//#define SNMG_DEBUG
#define SNMG_PR_T
namespace cugraph
{

  template<typename IndexType, typename ValueType>
__global__ void __launch_bounds__(CUDA_MAX_KERNEL_THREADS)
transition_kernel(const size_t e,
                  const IndexType *ind,
                  const IndexType *degree,
                  ValueType *val) {
  for (auto i = threadIdx.x + blockIdx.x * blockDim.x; 
       i < e; 
       i += gridDim.x * blockDim.x)
    val[i] = 1.0 / degree[ind[i]];
}

template <typename IndexType, typename ValueType>
SNMGpagerank<IndexType,ValueType>::SNMGpagerank(SNMGinfo & env_, size_t* part_off_, 
             IndexType * off_, IndexType * ind_) : 
             env(env_), part_off(part_off_), off(off_), ind(ind_) { 
  id = env.get_thread_num();
  nt = env.get_num_threads(); 
  v_glob = part_off[nt];
  v_loc = part_off[id+1]-part_off[id];
  IndexType tmp_e;
  cudaMemcpy(&tmp_e, &off[v_loc], sizeof(IndexType),cudaMemcpyDeviceToHost);
  cudaCheckError();
  e_loc = tmp_e;
  stream = nullptr;
  is_setup = false;
  ALLOC_TRY ((void**)&bookmark,   sizeof(ValueType) * v_glob, stream);
  ALLOC_TRY ((void**)&val, sizeof(ValueType) * e_loc, stream);

  // intialize cusparse. This can take some time.
  Cusparse::get_handle();
} 

template <typename IndexType, typename ValueType>
SNMGpagerank<IndexType,ValueType>::~SNMGpagerank() { 
  Cusparse::destroy_handle();
  ALLOC_FREE_TRY(bookmark, stream); 
  ALLOC_FREE_TRY(val, stream);
}

template <typename IndexType, typename ValueType>
void SNMGpagerank<IndexType,ValueType>::transition_vals(const IndexType *degree) {
  int threads = min(static_cast<IndexType>(e_loc), 256);
  int blocks = min(static_cast<IndexType>(32*env.get_num_sm()), CUDA_MAX_BLOCKS);
  transition_kernel<IndexType, ValueType> <<<blocks, threads>>> (e_loc, ind, degree, val);
  cudaCheckError();
}

template <typename IndexType, typename ValueType>
void SNMGpagerank<IndexType,ValueType>::flag_leafs(const IndexType *degree) {
  int threads = min(static_cast<IndexType>(v_glob), 256);
  int blocks = min(static_cast<IndexType>(32*env.get_num_sm()), CUDA_MAX_BLOCKS);
  flag_leafs_kernel<IndexType, ValueType> <<<blocks, threads>>> (v_glob, degree, bookmark);
  cudaCheckError();
}    


// Artificially create the google matrix by setting val and bookmark
template <typename IndexType, typename ValueType>
void SNMGpagerank<IndexType,ValueType>::setup(ValueType _alpha, IndexType** degree) {
  if (!is_setup) {

    alpha=_alpha;
    ValueType zero = 0.0; 
    IndexType *degree_loc;
    ALLOC_TRY ((void**)&degree_loc,   sizeof(IndexType) * v_glob, stream);
    degree[id] = degree_loc;
    if (snmg_degree(1, part_off, off, ind, degree))
       throw std::string("SNMG Degree failed in Pagerank");

    // Update dangling node vector
    fill(v_glob, bookmark, zero);
    flag_leafs(degree_loc);
    update_dangling_nodes(v_glob, bookmark, alpha);

    // Transition matrix
    transition_vals(degree_loc);

    //exit
    ALLOC_FREE_TRY(degree_loc, stream);
    is_setup = true;
  }
  else
    throw std::string("Setup can be called only once");
}

// run the power iteration on the google matrix
template <typename IndexType, typename ValueType>
void SNMGpagerank<IndexType,ValueType>::solve (int max_iter, ValueType ** pagerank) {
  if (is_setup) {
    ValueType  dot_res;
    ValueType one = 1.0;
    ValueType *pr = pagerank[id];
    fill(v_glob, pagerank[id], one/v_glob);
    // This cuda sync was added to fix #426
    // This should not be requiered in theory 
    // This is not needed on one GPU at this time
    cudaDeviceSynchronize();
    dot_res = dot( v_glob, bookmark, pr);
    SNMGcsrmv<IndexType,ValueType> spmv_solver(env, part_off, off, ind, val, pagerank);
    for (auto i = 0; i < max_iter; ++i) {
      spmv_solver.run(pagerank);
      scal(v_glob, alpha, pr);
      addv(v_glob, dot_res * (one/v_glob) , pr);
      dot_res = dot( v_glob, bookmark, pr);
      scal(v_glob, one/nrm2(v_glob, pr) , pr);
    }
    scal(v_glob, one/nrm1(v_glob,pr), pr);
  }
  else {
      throw std::string("Solve was called before setup");
  }
}

template class SNMGpagerank<int, double>;
template class SNMGpagerank<int, float>;


} //namespace cugraph

template<typename idx_t, typename val_t>
gdf_error gdf_snmg_pagerank_impl(
            gdf_column **src_col_ptrs, 
            gdf_column **dest_col_ptrs, 
            gdf_column *pr_col, 
            const size_t n_gpus, 
            const float damping_factor, 
            const int n_iter) {
  
  // Must be shared
  // Set during coo2csr and used in PageRank
  std::vector<size_t> part_offset(n_gpus+1);

  // Must be shared. 
  // When a thread encounters an error it will update this value 
  // using a critical section
  gdf_error status = GDF_SUCCESS;

  // Pagerank specific.
  // must be shared between threads
  idx_t *degree[n_gpus];
  val_t* pagerank[n_gpus];

  // coo2csr specific.
  // used to communicate global info such as patition offsets 
  // must be shared
  void* coo2csr_comm; 

  #pragma omp parallel num_threads(n_gpus)
  {
    #ifdef SNMG_PR_T
      double t = omp_get_wtime();
    #endif
    // Setting basic SNMG env information
    cudaSetDevice(omp_get_thread_num());
    cugraph::SNMGinfo env;
    auto i = env.get_thread_num();
    auto p = env.get_num_threads();
    cudaCheckError();

    // Local CSR columns
    gdf_column *col_csr_off = new gdf_column;
    gdf_column *col_csr_ind = new gdf_column;

    // distributed coo2csr
    // notice that source and destination input are swapped 
    // this is becasue pagerank needs the transposed CSR
    // the resulting csr matrix is the transposed adj list
    gdf_error status_i = gdf_snmg_coo2csr(
                           &part_offset[0],
                           false,
                           &coo2csr_comm,   
                           dest_col_ptrs[i],
                           src_col_ptrs[i],
                           nullptr,
                           col_csr_off,
                           col_csr_ind,
                           nullptr);
    // coo2csr time
    #ifdef SNMG_PR_T
      #pragma omp master 
      {std::cout <<  omp_get_wtime() - t << " ";}
      t = omp_get_wtime();
    #endif
    // checking coo2csr return code
    if (status_i != GDF_SUCCESS)
    {
      #pragma omp critical
      status = status_i;
    }
    // Allocate and intialize Pagerank class
    cugraph::SNMGpagerank<idx_t,val_t> pr_solver(env, &part_offset[0], 
                                static_cast<idx_t*>(col_csr_off->data), 
                                static_cast<idx_t*>(col_csr_ind->data));

    // Set all constants info, call the SNMG degree feature
    pr_solver.setup(damping_factor,degree);

    // Setup time
    #ifdef SNMG_PR_T
      #pragma omp master 
      {std::cout <<  omp_get_wtime() - t << " ";}
      t = omp_get_wtime();
    #endif

    ALLOC_TRY ((void**)&pagerank[i],   sizeof(val_t) * part_offset[p], nullptr);

    // Run n_iter pagerank MG SPMVs. 
    pr_solver.solve(n_iter, pagerank);

    // set the result in the gdf column
    #pragma omp master
    {
      //default gdf values
      cugraph::gdf_col_set_defaults(pr_col);

      //fill relevant fields
      ALLOC_TRY ((void**)&pr_col->data,   sizeof(val_t) * part_offset[p], nullptr);
      cudaMemcpy(pr_col->data, pagerank[i], sizeof(val_t) * part_offset[p], cudaMemcpyDeviceToDevice);
      cudaCheckError();
      pr_col->size = part_offset[p];
      pr_col->dtype = GDF_FLOAT32;
    }
    // Power iteration time
    #ifdef SNMG_PR_T
      #pragma omp master 
      {std::cout <<  omp_get_wtime() - t << std::endl;}
    #endif
    // Free
    gdf_col_delete(col_csr_off);
    gdf_col_delete(col_csr_ind);
    ALLOC_FREE_TRY(pagerank[i], nullptr);
  }

  return status;
}

gdf_error gdf_snmg_pagerank (
            gdf_column **src_col_ptrs, 
            gdf_column **dest_col_ptrs, 
            gdf_column *pr_col, 
            const size_t n_gpus, 
            const float damping_factor = 0.85, 
            const int n_iter = 10) {
    // null pointers check
    GDF_REQUIRE(src_col_ptrs != nullptr, GDF_INVALID_API_CALL);
    GDF_REQUIRE(dest_col_ptrs != nullptr, GDF_INVALID_API_CALL);
    GDF_REQUIRE(pr_col != nullptr, GDF_INVALID_API_CALL);

    // parameter values
    GDF_REQUIRE(damping_factor > 0.0, GDF_INVALID_API_CALL);
    GDF_REQUIRE(damping_factor < 1.0, GDF_INVALID_API_CALL);
    GDF_REQUIRE(n_iter > 0, GDF_INVALID_API_CALL);
    // number of GPU
    int dev_count;
    cudaGetDeviceCount(&dev_count);
    cudaCheckError();
    GDF_REQUIRE(n_gpus > 0, GDF_INVALID_API_CALL);
    GDF_REQUIRE(n_gpus < static_cast<size_t>(dev_count+1), GDF_INVALID_API_CALL); 

    // for each GPU
    for (size_t i = 0; i < n_gpus; ++i)
    {
      // src/dest consistency
      GDF_REQUIRE( src_col_ptrs[i]->size == dest_col_ptrs[i]->size, GDF_COLUMN_SIZE_MISMATCH );
      GDF_REQUIRE( src_col_ptrs[i]->dtype == dest_col_ptrs[i]->dtype, GDF_UNSUPPORTED_DTYPE );
      //null mask
      GDF_REQUIRE( src_col_ptrs[i]->null_count == 0 , GDF_VALIDITY_UNSUPPORTED );
      GDF_REQUIRE( dest_col_ptrs[i]->null_count == 0 , GDF_VALIDITY_UNSUPPORTED );
      // int 32 edge list indices
      GDF_REQUIRE( src_col_ptrs[i]->dtype == GDF_INT32, GDF_UNSUPPORTED_DTYPE);
      GDF_REQUIRE( dest_col_ptrs[i]->dtype == GDF_INT32, GDF_UNSUPPORTED_DTYPE);
    }

    gdf_error status =  gdf_snmg_pagerank_impl<int, float>(src_col_ptrs, dest_col_ptrs,
                                  pr_col, n_gpus, damping_factor, n_iter);
    return status;

}
