#include "common.h"
#include "naive.h"
#include <cuda.h>
#include <cuda_runtime.h>

namespace StreamCompaction {
namespace Naive {
using StreamCompaction::Common::PerformanceTimer;
PerformanceTimer &timer() {
  static PerformanceTimer timer;
  return timer;
}
__global__ void shift_array(int n, const int *d_idata, int *d_odata) {
  int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx < n)
    d_odata[idx] = (idx == 0) ? 0 : d_idata[idx - 1];
}

__global__ void scanKernel(int n, const int *d_idata, int *d_odata,
                           int offset) {
  int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx < n) {
    if (idx >= offset)
      d_odata[idx] = d_idata[idx] + d_idata[idx - offset];
    else
      d_odata[idx] = d_idata[idx];
  }
}

void scan(int n, int *odata, const int *idata) {
  int *d_idata, *d_odata;
  cudaMalloc((void **)&d_idata, n * sizeof(int));
  cudaMalloc((void **)&d_odata, n * sizeof(int));
  cudaMemcpy(d_idata, idata, n * sizeof(int), cudaMemcpyHostToDevice);

  static constexpr int BLOCK_SIZE = 512;
  int numBlocks = (n + BLOCK_SIZE - 1) / BLOCK_SIZE;

  timer().startGpuTimer();
  shift_array<<<numBlocks, BLOCK_SIZE>>>(n, d_idata, d_odata);
  std::swap(d_idata, d_odata);
  cudaDeviceSynchronize();

  int rounds = 0;
  for (int offset = 1; offset < n; offset *= 2) {
    scanKernel<<<numBlocks, BLOCK_SIZE>>>(n, d_idata, d_odata, offset);
    std::swap(d_idata, d_odata);
  }
  timer().endGpuTimer();

  // 判断最后结果在哪个buffer
  cudaMemcpy(odata, d_idata, n * sizeof(int), cudaMemcpyDeviceToHost);

  cudaFree(d_idata);
  cudaFree(d_odata);
}

} // namespace Naive
} // namespace StreamCompaction
