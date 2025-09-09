// #include <__clang_cuda_builtin_vars.h>
#include "common.cuh"
// #include <__clang_cuda_runtime_wrapper.h>
// #include <__clang_cuda_builtin_vars.h>
#include <cublas_v2.h>
#include <cuda_runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>

constexpr int BLOCK_SIZE_SHIFT_BIT = 5;
constexpr int BLOCK_SIZE = (1 << BLOCK_SIZE_SHIFT_BIT);
constexpr int COMPUTE_PER_THREAD_SHIFT_BIT = 3;
constexpr int COMPUTE_PER_THREAD = (1 << COMPUTE_PER_THREAD_SHIFT_BIT);

__global__ void naive_gemm_kernel(const FLOAT *A, const FLOAT *B, FLOAT *C,
                                  int M, int N, int K) {
  int row = blockIdx.y * blockDim.y + threadIdx.y;
  int col = blockIdx.x * blockDim.x + threadIdx.x;

  if (row < M && col < N) {
    FLOAT sum = 0;
    for (int k = 0; k < K; ++k) {
      sum += A[row * K + k] * B[k * N + col];
    }
    C[row * N + col] = sum;
  }
}

__global__ void naive_gemm_kernel_coalesced(FLOAT *A, FLOAT *B, FLOAT *C, int M,
                                            int N, int K) {
    A += (blockIdx.x * blockDim.x) * K;
    B += (blockIdx.y * blockDim.y);
    C += (blockIdx.x * blockDim.x) * N + (blockIdx.y * blockDim.y);
    int x = threadIdx.x >> BLOCK_SIZE_SHIFT_BIT;
    int y = threadIdx.x & (BLOCK_SIZE - 1);
    FLOAT sum = 0;
    for (int k = 0; k < K; ++k) {
      sum += A[x * K + k] * B[k * N + y];
    }
    C[x * N + y] = sum;
}


__global__ void naive_tiled_gemm_kernel(FLOAT *A, FLOAT *B, FLOAT *C, int M,
                                            int N, int K) {
    A += (blockIdx.x * blockDim.x) * K;
    B += (blockIdx.y * blockDim.y);
    C += (blockIdx.x * blockDim.x) * N + (blockIdx.y * blockDim.y);
    int x = threadIdx.x >> BLOCK_SIZE_SHIFT_BIT;
    int y = threadIdx.x & (BLOCK_SIZE - 1);
    __shared__ FLOAT As[BLOCK_SIZE][BLOCK_SIZE];
    __shared__ FLOAT Bs[BLOCK_SIZE][BLOCK_SIZE];
    FLOAT sum = 0;
    for (int i=0; i<K; i+=BLOCK_SIZE) {
        // load shared memory
        As[x][y] = A[x*K + y];
        Bs[x][y] = B[x*N + y];
        __syncthreads();
        A += BLOCK_SIZE;
        B += BLOCK_SIZE * N;
        // compute on the tile
        for (int k = 0; k < BLOCK_SIZE; ++k) {
            sum += As[x][k] * Bs[k][y];
        }
    }
    C[x * N + y] = sum;
}


__global__ void tiled_gemm_kernel_more_compute(FLOAT *A, FLOAT *B, FLOAT *C, int M,
                                            int N, int K) {
    A += (blockIdx.x * blockDim.x) * K;
    B += (blockIdx.y * blockDim.y);
    C += (blockIdx.x * blockDim.x) * N + (blockIdx.y * blockDim.y);
    int x = threadIdx.x >> BLOCK_SIZE_SHIFT_BIT;
    int y = threadIdx.x & (BLOCK_SIZE - 1);
    __shared__ FLOAT As[BLOCK_SIZE][BLOCK_SIZE];
    __shared__ FLOAT Bs[BLOCK_SIZE][BLOCK_SIZE];
    FLOAT sum[COMPUTE_PER_THREAD] = {0.0f};
    for (int i=0; i<K; i+=BLOCK_SIZE) {
        // load shared memory
        As[x][y] = A[x*K + y];
        Bs[x][y] = B[x*N + y];
        __syncthreads();
        A += BLOCK_SIZE;
        B += BLOCK_SIZE * N;
        // compute on the tile
        for (int k = 0; k < BLOCK_SIZE; ++k) {
            for (int j = 0; j < COMPUTE_PER_THREAD; ++j) {
                sum[j] += As[x+j][k] * Bs[k][y];
            }
        }
    }
    for (int j = 0; j < COMPUTE_PER_THREAD; ++j) {
        C[(x+j)*N+y] = sum[j];
    }
}

__global__ void tiled_gemm_kernel_even_more_compute(FLOAT *A, FLOAT *B, FLOAT *C, int M,
                                            int N, int K) {
    A += (blockIdx.x * blockDim.x) * K;
    B += (blockIdx.y * blockDim.y);
    C += (blockIdx.x * blockDim.x) * N + (blockIdx.y * blockDim.y);
    int x = threadIdx.x / (BLOCK_SIZE/COMPUTE_PER_THREAD);
    int y = threadIdx.x % (BLOCK_SIZE/COMPUTE_PER_THREAD);
    __shared__ FLOAT As[BLOCK_SIZE][BLOCK_SIZE];
    __shared__ FLOAT Bs[BLOCK_SIZE][BLOCK_SIZE];
    FLOAT sum[COMPUTE_PER_THREAD][COMPUTE_PER_THREAD] = {0.0f};
    FLOAT regA[COMPUTE_PER_THREAD] = {0.0f};
    FLOAT regB[COMPUTE_PER_THREAD] = {0.0f};
    for (int i=0; i<K; i+=BLOCK_SIZE) {
        // load shared memory
        As[x][y] = A[x*K + y];
        Bs[x][y] = B[x*N + y];
        __syncthreads();
        A += BLOCK_SIZE;
        B += BLOCK_SIZE * N;

        // compute on the tile
        for (int k = 0; k < BLOCK_SIZE; ++k) {

            for(int q=0;q<COMPUTE_PER_THREAD;q++){
                regA[q] = As[x+q][k];
                regB[q] = Bs[k][y+q];
            }


            for (int inner_i = 0; inner_i < COMPUTE_PER_THREAD; inner_i++) {
                for (int inner_j = 0; inner_j < COMPUTE_PER_THREAD; inner_j++) {
                    sum[inner_i][inner_j] += regA[inner_i] * regB[inner_j];
                }
            }
        }
    }
    for(int i=0;i<COMPUTE_PER_THREAD;i++){
        for(int j=0;j<COMPUTE_PER_THREAD;j++){
            C[(x+i)*N+y+j] = sum[i][j];
        }
    }
}



int main() {
    return 0;
}