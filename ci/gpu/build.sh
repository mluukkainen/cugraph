#!/usr/bin/env bash
# Copyright (c) 2018, NVIDIA CORPORATION.
##########################################
# cuGraph GPU build & testscript for CI  #
##########################################
set -e
NUMARGS=$#
ARGS=$*

# Logger function for build status output
function logger() {
  echo -e "\n>>>> $@\n"
}

# Arg parsing function
function hasArg {
    (( ${NUMARGS} != 0 )) && (echo " ${ARGS} " | grep -q " $1 ")
}

# Set path, build parallel level, and CUDA version
export PATH=/conda/bin:/usr/local/cuda/bin:$PATH
export PARALLEL_LEVEL=4
export CUDA_REL=${CUDA_VERSION%.*}

# Set home to the job's workspace
export HOME=$WORKSPACE

# Parse git describe
cd $WORKSPACE
export GIT_DESCRIBE_TAG=`git describe --tags`
export MINOR_VERSION=`echo $GIT_DESCRIBE_TAG | grep -o -E '([0-9]+\.[0-9]+)'`

################################################################################
# SETUP - Check environment
################################################################################

logger "Check environment..."
env

logger "Check GPU usage..."
nvidia-smi

logger "Activate conda env..."
source activate gdf
conda install -c nvidia/label/cuda$CUDA_REL -c rapidsai/label/cuda$CUDA_REL -c rapidsai-nightly/label/cuda$CUDA_REL -c numba -c conda-forge \
      cudf=${MINOR_VERSION} \
      rmm=${MINOR_VERSION} \
      networkx \
      python-louvain \
      cudatoolkit=$CUDA_REL \
      dask \
      distributed \
      dask-cudf=${MINOR_VERSION} \
      dask-cuda=${MINOR_VERSION}

logger "Check versions..."
python --version
$CC --version
$CXX --version
conda list

################################################################################
# BUILD - Build libcugraph and cuGraph from source
################################################################################

logger "Build libcugraph..."
$WORKSPACE/build.sh clean libcugraph cugraph

################################################################################
# TEST - Run GoogleTest and py.tests for libcugraph and cuGraph
################################################################################

if hasArg --skip-tests; then
    logger "Skipping Tests..."
else
    logger "Check GPU usage..."
    nvidia-smi

    logger "GoogleTest for libcugraph..."
    cd $WORKSPACE/cpp/build
    GTEST_OUTPUT="xml:${WORKSPACE}/test-results/" gtests/GDFGRAPH_TEST

    logger "Python py.test for cuGraph..."
    cd $WORKSPACE/python
    py.test --cache-clear --junitxml=${WORKSPACE}/junit-cugraph.xml -v
fi

