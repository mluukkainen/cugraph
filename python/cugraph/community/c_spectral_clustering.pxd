# Copyright (c) 2019, NVIDIA CORPORATION.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# cython: profile=False
# distutils: language = c++
# cython: embedsignature = True
# cython: language_level = 3

from cugraph.structure.c_graph cimport *


cdef extern from "nvgraph_gdf.h":

    cdef gdf_error gdf_balancedCutClustering_nvgraph(
        gdf_graph *gdf_G,
        const int num_clusters,
        const int num_eigen_vects,
        const float evs_tolerance,
        const int evs_max_iter,
        const float kmean_tolerance,
        const int kmean_max_iter,
        gdf_column* clustering) except +
    
    cdef gdf_error gdf_spectralModularityMaximization_nvgraph(
        gdf_graph* gdf_G,
        const int n_clusters,
        const int n_eig_vects,
        const float evs_tolerance,
        const int evs_max_iter,
        const float kmean_tolerance,
        const int kmean_max_iter,
        gdf_column* clustering) except +
    
    cdef gdf_error gdf_AnalyzeClustering_modularity_nvgraph(
        gdf_graph* gdf_G,
        const int n_clusters,
        gdf_column* clustering,
        float* score) except +
    
    cdef gdf_error gdf_AnalyzeClustering_edge_cut_nvgraph(
        gdf_graph* gdf_G,
        const int n_clusters,
        gdf_column* clustering,
        float* score) except +
    
    cdef gdf_error gdf_AnalyzeClustering_ratio_cut_nvgraph(
        gdf_graph* gdf_G,
        const int n_clusters,
        gdf_column* clustering,
        float* score) except +
