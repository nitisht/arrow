#!/bin/bash
#
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
#
# Build upon the scripts in https://github.com/matthew-brett/manylinux-builds
# * Copyright (c) 2013-2016, Matt Terry and Matthew Brett (BSD 2-clause)
#
# Usage:
#   either build:
#     $ docker-compose build python-manylinux1
#   or pull:
#     $ docker-compose pull python-manylinux1
#   and then run:
#     $ docker-compose run -e PYTHON_VERSION=3.7 python-manylinux1

source /multibuild/manylinux_utils.sh

# Quit on failure
set -e

# Print commands for debugging
# set -x

cd /arrow/python

NCORES=$(($(grep -c ^processor /proc/cpuinfo) + 1))

# PyArrow build configuration
export PYARROW_BUILD_TYPE='release'
export PYARROW_CMAKE_GENERATOR='Ninja'
export PYARROW_PARALLEL=${NCORES}

# ARROW-6860: Disabling ORC in wheels until Protobuf static linking issues
# across projects is resolved
export PYARROW_WITH_ORC=0
export PYARROW_WITH_HDFS=1
export PYARROW_WITH_PARQUET=1
export PYARROW_WITH_PLASMA=1
export PYARROW_WITH_S3=1
export PYARROW_BUNDLE_ARROW_CPP=1
export PYARROW_BUNDLE_BOOST=1
export PYARROW_BOOST_NAMESPACE=arrow_boost
export PKG_CONFIG_PATH=/usr/lib/pkgconfig:/arrow-dist/lib/pkgconfig

export PYARROW_CMAKE_OPTIONS='-DTHRIFT_HOME=/usr -DBoost_NAMESPACE=arrow_boost -DBOOST_ROOT=/arrow_boost_dist'
# Ensure the target directory exists
mkdir -p /io/dist

# Must pass PYTHON_VERSION env variable
# possible values are: 3.6 3.7 3.8

UNICODE_WIDTH=32  # Dummy value, irrelevant for Python 3
CPYTHON_PATH="$(cpython_path ${PYTHON_VERSION} ${UNICODE_WIDTH})"
PYTHON_INTERPRETER="${CPYTHON_PATH}/bin/python"
PIP="${CPYTHON_PATH}/bin/pip"
# Put our Python first to avoid picking up an antiquated Python from CMake
PATH="${CPYTHON_PATH}/bin:${PATH}"

echo "=== (${PYTHON_VERSION}) Install the wheel build dependencies ==="
$PIP install -r requirements-wheel-build.txt

export PYARROW_INSTALL_TESTS=1
export PYARROW_WITH_DATASET=1
export PYARROW_WITH_FLIGHT=1
export PYARROW_WITH_GANDIVA=0
export BUILD_ARROW_DATASET=ON
export BUILD_ARROW_FLIGHT=ON
export BUILD_ARROW_GANDIVA=OFF

echo "=== (${PYTHON_VERSION}) Building Arrow C++ libraries ==="
ARROW_BUILD_DIR=/tmp/build-PY${PYTHON_VERSION}
mkdir -p "${ARROW_BUILD_DIR}"
pushd "${ARROW_BUILD_DIR}"
cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DARROW_BOOST_USE_SHARED=ON \
    -DARROW_BROTLI_USE_SHARED=OFF \
    -DARROW_BUILD_SHARED=ON \
    -DARROW_BUILD_STATIC=OFF \
    -DARROW_BUILD_TESTS=OFF \
    -DARROW_DATASET=${BUILD_ARROW_DATASET} \
    -DARROW_DEPENDENCY_SOURCE="SYSTEM" \
    -DARROW_DEPENDENCY_USE_SHARED=OFF \
    -DARROW_FLIGHT=${BUILD_ARROW_FLIGHT} \
    -DARROW_GANDIVA_JAVA=OFF \
    -DARROW_GANDIVA_PC_CXX_FLAGS="-isystem;/opt/rh/devtoolset-2/root/usr/include/c++/4.8.2;-isystem;/opt/rh/devtoolset-2/root/usr/include/c++/4.8.2/x86_64-CentOS-linux/" \
    -DARROW_GANDIVA=${BUILD_ARROW_GANDIVA} \
    -DARROW_HDFS=ON \
    -DARROW_JEMALLOC=ON \
    -DARROW_ORC=OFF \
    -DARROW_PACKAGE_KIND=manylinux1 \
    -DARROW_PARQUET=ON \
    -DARROW_PLASMA=ON \
    -DARROW_PYTHON=ON \
    -DARROW_RPATH_ORIGIN=ON \
    -DARROW_S3=ON \
    -DARROW_TENSORFLOW=ON \
    -DARROW_UTF8PROC_USE_SHARED=OFF \
    -DARROW_WITH_BROTLI=ON \
    -DARROW_WITH_BZ2=ON \
    -DARROW_WITH_LZ4=ON \
    -DARROW_WITH_SNAPPY=ON \
    -DARROW_WITH_ZLIB=ON \
    -DARROW_WITH_ZSTD=ON \
    -DBoost_NAMESPACE=arrow_boost \
    -DBOOST_ROOT=/arrow_boost_dist \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_INSTALL_PREFIX=/arrow-dist \
    -DCMAKE_UNITY_BUILD=ON \
    -DOPENSSL_USE_STATIC_LIBS=ON \
    -DORC_SOURCE=BUNDLED \
    -GNinja /arrow/cpp
ninja
ninja install
popd

# Check that we don't expose any unwanted symbols
/io/scripts/check_arrow_visibility.sh

# Clear output directories and leftovers
rm -rf dist/
rm -rf build/
rm -rf repaired_wheels/
find -name "*.so" -delete

echo "=== (${PYTHON_VERSION}) Building wheel ==="
PATH="$PATH:${CPYTHON_PATH}/bin" $PYTHON_INTERPRETER setup.py build_ext --inplace
PATH="$PATH:${CPYTHON_PATH}/bin" $PYTHON_INTERPRETER setup.py bdist_wheel
# Source distribution is used for debian pyarrow packages.
PATH="$PATH:${CPYTHON_PATH}/bin" $PYTHON_INTERPRETER setup.py sdist

if [ -n "$UBUNTU_WHEELS" ]; then
  echo "=== (${PYTHON_VERSION}) Wheels are not compatible with manylinux1 ==="
  mv dist/pyarrow-*.whl /io/dist
else
  echo "=== (${PYTHON_VERSION}) Tag the wheel with manylinux1 ==="
  mkdir -p repaired_wheels/
  auditwheel repair -L . dist/pyarrow-*.whl -w repaired_wheels/

  # Install the built wheels
  $PIP install repaired_wheels/*.whl

  # Test that the modules are importable
  $PYTHON_INTERPRETER -c "
import pyarrow
import pyarrow.csv
import pyarrow.dataset
import pyarrow.flight
import pyarrow.fs
import pyarrow._hdfs
import pyarrow.json
import pyarrow.parquet
import pyarrow.plasma
import pyarrow._s3fs
  "

  # More thorough testing happens outside of the build to prevent
  # packaging issues like ARROW-4372
  mv dist/*.tar.gz /io/dist
  mv repaired_wheels/*.whl /io/dist
fi
