#include "common.h"
#include "efficient.h"
#include <cuda.h>
#include <cuda_runtime.h>

namespace StreamCompaction {
namespace Efficient {
using StreamCompaction::Common::PerformanceTimer;
PerformanceTimer &timer() {
  static PerformanceTimer timer;
  return timer;
}

__global__ void up_sweep(int n, int *data) {
  int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx >= n)
    return;
  __syncthreads();
  for (int d = 1; d < n; d *= 2) {
    int k = (idx + 1) * d * 2 - 1; // k = (idx + 1) * d * 2 - 1
    if (k < n) {
      data[k] += data[k - d];
    }
    __syncthreads();
  }
}

__global__ void down_sweep(int n, int *data) {
  int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx == n - 1)
    data[idx] = 0; // Set the last element to 0
  __syncthreads();
  for (int d = n / 2; d >= 1; d /= 2) {
    int k = (idx + 1) * d * 2 - 1; // k = (idx + 1) * d * 2 - 1
    if (k < n) {
      int temp = data[k];
      data[k] += data[k - d];
      data[k - d] = temp;
    }
    __syncthreads();
  }
}

/**
 * Performs prefix-sum (aka scan) on idata, storing the result into odata.
 */
void scan(int n, int *odata, const int *idata) {
  // TODO
  int *d_idata, *d_odata;
  cudaMalloc((void **)&d_idata, n * sizeof(int));
  cudaMalloc((void **)&d_odata, n * sizeof(int));
  cudaMemcpy(d_idata, idata, n * sizeof(int), cudaMemcpyHostToDevice);
  static constexpr int BLOCK_SIZE = 512;
  int numBlocks = (n + BLOCK_SIZE - 1) / BLOCK_SIZE;
  timer().startGpuTimer();
  // Step 1: Up-sweep (reduce)
  up_sweep<<<numBlocks, BLOCK_SIZE>>>(n, d_idata);
  cudaDeviceSynchronize();
  // Step 2: Down-sweep
  down_sweep<<<numBlocks, BLOCK_SIZE>>>(n, d_idata);
  cudaDeviceSynchronize();
  timer().endGpuTimer();
  // Step 3: Copy to odata
  cudaMemcpy(odata, d_idata, n * sizeof(int), cudaMemcpyDeviceToHost);
  cudaFree(d_idata);
  cudaFree(d_odata);
}

/**
 * Performs stream compaction on idata, storing the result into odata.
 * All zeroes are discarded.
 *
 * @param n      The number of elements in idata.
 * @param odata  The array into which to store elements.
 * @param idata  The array of elements to compact.
 * @returns      The number of elements remaining after compaction.
 */
int compact(int n, int *odata, const int *idata) {
  timer().startGpuTimer();

  timer().endGpuTimer();
  return -1;
}
} // namespace Efficient
} // namespace StreamCompaction
