/*
 * Copyright (c) 2018-2020, NVIDIA CORPORATION.
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

#include "../test_utils.h"
#include "unary_op.cuh"
#include <gtest/gtest.h>
#include <raft/cudart_utils.h>
#include <raft/linalg/divide.cuh>
#include <raft/random/rng.hpp>

namespace raft {
namespace linalg {

template <typename Type>
__global__ void naiveDivideKernel(Type* out, const Type* in, Type scalar, int len)
{
  int idx = threadIdx.x + blockIdx.x * blockDim.x;
  if (idx < len) { out[idx] = in[idx] / scalar; }
}

template <typename Type>
void naiveDivide(Type* out, const Type* in, Type scalar, int len, cudaStream_t stream)
{
  static const int TPB = 64;
  int nblks            = raft::ceildiv(len, TPB);
  naiveDivideKernel<Type><<<nblks, TPB, 0, stream>>>(out, in, scalar, len);
  RAFT_CUDA_TRY(cudaPeekAtLastError());
}

template <typename T>
class DivideTest : public ::testing::TestWithParam<raft::linalg::UnaryOpInputs<T>> {
 public:
  DivideTest()
    : params(::testing::TestWithParam<raft::linalg::UnaryOpInputs<T>>::GetParam()),
      stream(handle.get_stream()),
      in(params.len, stream),
      out_ref(params.len, stream),
      out(params.len, stream)
  {
  }

 protected:
  void SetUp() override
  {
    raft::random::Rng r(params.seed);
    int len = params.len;
    RAFT_CUDA_TRY(cudaStreamCreate(&stream));
    r.uniform(in.data(), len, T(-1.0), T(1.0), stream);
    naiveDivide(out_ref.data(), in.data(), params.scalar, len, stream);
    divideScalar(out.data(), in.data(), params.scalar, len, stream);
    RAFT_CUDA_TRY(cudaStreamSynchronize(stream));
  }

 protected:
  raft::handle_t handle;
  cudaStream_t stream;

  UnaryOpInputs<T> params;
  rmm::device_uvector<T> in;
  rmm::device_uvector<T> out_ref;
  rmm::device_uvector<T> out;
};

const std::vector<UnaryOpInputs<float>> inputsf = {{0.000001f, 1024 * 1024, 2.f, 1234ULL}};
typedef DivideTest<float> DivideTestF;
TEST_P(DivideTestF, Result)
{
  ASSERT_TRUE(devArrMatch(
    out_ref.data(), out.data(), params.len, raft::CompareApprox<float>(params.tolerance), stream));
}
INSTANTIATE_TEST_SUITE_P(DivideTests, DivideTestF, ::testing::ValuesIn(inputsf));

typedef DivideTest<double> DivideTestD;
const std::vector<UnaryOpInputs<double>> inputsd = {{0.000001f, 1024 * 1024, 2.f, 1234ULL}};
TEST_P(DivideTestD, Result)
{
  ASSERT_TRUE(devArrMatch(
    out_ref.data(), out.data(), params.len, raft::CompareApprox<double>(params.tolerance), stream));
}
INSTANTIATE_TEST_SUITE_P(DivideTests, DivideTestD, ::testing::ValuesIn(inputsd));

}  // end namespace linalg
}  // end namespace raft
