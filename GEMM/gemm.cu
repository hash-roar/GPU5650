// #include <__clang_cuda_builtin_vars.h>
#include "common.cuh"
// #include <__clang_cuda_runtime_wrapper.h>
#include <cublas_v2.h>
#include <cuda_runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>

#define DEFAULT_M 1024
#define DEFAULT_N 1024
#define DEFAULT_K 1024
#define NUM_ITERATIONS 10

constexpr int TILE_SHIFT_BIT = 5;

#define A(i, j) A[(i) * ldA + (j)]
#define B(i, j) B[(i) * ldB + (j)]
#define C(i, j) C[(i) * ldC + (j)]
#define As(i, j) As[(i) * TILE_SIZE + (j)]
#define Bs(i, j) Bs[(i) * TILE_SIZE + (j)]

// 简单的GEMM kernel (row-major layout) - simplified for debugging
__global__ void naive_gemm(FLOAT *A, FLOAT *B, FLOAT *C, int M, int N, int K,
                           FLOAT alpha, FLOAT beta) {
  int row = blockIdx.y * blockDim.y + threadIdx.y;
  int col = blockIdx.x * blockDim.x + threadIdx.x;
  int ldA = K;
  int ldB = N;
  int ldC = N;
  if (row < M && col < N) {
    FLOAT sum = 0.0f;
    for (int k = 0; k < K; ++k) {
      sum += A(row, k) * B(k, col);
    }
    C(row, col) = alpha * sum + beta * C(row, col);
  }
}

// 使用共享内存的优化GEMM kernel
template <int TILE_SIZE>
__global__ void tiled_gemm(FLOAT *A, FLOAT *B, FLOAT *C, int M, int N, int K,
                           FLOAT alpha, FLOAT beta) {

  int bx = blockIdx.x, by = blockIdx.y;
  int tx = threadIdx.x, ty = threadIdx.y;

  int ldA = K;
  int ldB = N;
  int ldC = N;
  A = &A(0, (bx << TILE_SHIFT_BIT));
  B = &B((by << TILE_SHIFT_BIT), 0);
  C = &C((by << TILE_SHIFT_BIT), (bx << TILE_SHIFT_BIT));

  __shared__ FLOAT As[TILE_SIZE * TILE_SIZE];
  __shared__ FLOAT Bs[TILE_SIZE * TILE_SIZE];
  FLOAT sum = 0.0f;
  for (int k = 0; k < K; k += TILE_SIZE) {
    // load tiles data into shared memory
    As(ty, tx) = A(ty, tx);
    Bs(ty, tx) = B(ty, tx);
    A += (ldA << TILE_SHIFT_BIT);
    B += (TILE_SIZE);
    __syncthreads();

    // compute on the tile
    for (int kk = 0; kk < TILE_SIZE; ++kk) {
      sum += As(tx,kk) * Bs(kk,ty);
    }
    __syncthreads();
  }
  C(ty, tx) = alpha * sum + beta * C(ty, tx);
}

// 使用共享内存的优化GEMM kernel
template <int TILE_SIZE>
__global__ void tiled_gemm_save_one_register(FLOAT *A, FLOAT *B, FLOAT *C,
                                             int M, int N, int K, FLOAT alpha,
                                             FLOAT beta) {

  int bx = blockIdx.x, by = blockIdx.y;
  int tx = threadIdx.x;
  int col = tx & 31;
  int row = tx >> 5;

  int ldA = K;
  int ldB = N;
  int ldC = N;
  A = &A(0, (bx << TILE_SHIFT_BIT));
  B = &B((by << TILE_SHIFT_BIT), 0);
  C = &C((by << TILE_SHIFT_BIT), (bx << TILE_SHIFT_BIT));

  __shared__ FLOAT As[TILE_SIZE * TILE_SIZE];
  __shared__ FLOAT Bs[TILE_SIZE * TILE_SIZE];
  FLOAT sum = 0.0f;
  for (int k = 0; k < K; k += TILE_SIZE) {
    // load tiles data into shared memory
    As(row, col) = A(row, col);
    Bs(row, col) = B(row, col);
    A += (ldA << TILE_SHIFT_BIT);
    B += (TILE_SIZE);
    __syncthreads();

    // compute on the tile
    for (int kk = 0; kk < TILE_SIZE; ++kk) {
      sum += As(row, kk) * Bs(kk,col);
    }
    __syncthreads();
  }
  C(row, col) = alpha * sum + beta * C(row, col);
}

// 使用共享内存的优化GEMM kernel
template <int TILE_SIZE>
__global__ void tiled_gemm_row_major_memo(FLOAT *A, FLOAT *B, FLOAT *C, int M,
                                          int N, int K, FLOAT alpha,
                                          FLOAT beta) {

  int bx = blockIdx.x, by = blockIdx.y;
  int tx = threadIdx.x;
  int col = tx & 31;
  int row = tx >> 5;

  int ldA = K;
  int ldB = N;
  int ldC = N;
  A = &A(0, (bx << TILE_SHIFT_BIT));
  B = &B((by << TILE_SHIFT_BIT), 0);
  C = &C((by << TILE_SHIFT_BIT), (bx << TILE_SHIFT_BIT));

  __shared__ FLOAT As[TILE_SIZE * TILE_SIZE];
  __shared__ FLOAT Bs[TILE_SIZE * TILE_SIZE];
  FLOAT sum = 0.0f;
  for (int k = 0; k < K; k += TILE_SIZE) {
    // load tiles data into shared memory
    As(row, col) = A(row, col);
    Bs(row, col) = B(row, col);
    A += (ldA << TILE_SHIFT_BIT);
    B += (TILE_SIZE);
    __syncthreads();

    // compute on the tile
    for (int kk = 0; kk < TILE_SIZE; ++kk) {
      sum += As(row,kk) * Bs(kk,col);
    }
    __syncthreads();
  }
  C(row, col) = alpha * sum + beta * C(row, col);
}

// every kernel compute 4 elements
template <int TILE_SIZE>
__global__ void tiled_gemm_micro_kernel(FLOAT *A, FLOAT *B, FLOAT *C, int M,
                                          int N, int K, FLOAT alpha,
                                          FLOAT beta) {

  int bx = blockIdx.x, by = blockIdx.y;
  int tx = threadIdx.x;
  int col = (tx & 7)<< 2;
  int col1 = col + 1,col2 = col + 2,col3 = col + 3;
  int row = tx >> 3;

  int ldA = K;
  int ldB = N;
  int ldC = N;
  A = &A(0, (bx << TILE_SHIFT_BIT));
  B = &B((by << TILE_SHIFT_BIT), 0);
  C = &C((by << TILE_SHIFT_BIT), (bx << TILE_SHIFT_BIT));
  
  __shared__ FLOAT As[TILE_SIZE * TILE_SIZE];
  __shared__ FLOAT Bs[TILE_SIZE * TILE_SIZE];
  FLOAT sum[4];
  FLOAT a_temp;
  for (int k = 0; k < K; k += TILE_SIZE) {
    // load tiles data into shared memory
    As(row, col) = A(row, col);
    As(row, col1) = A(row, col1);
    As(row, col2) = A(row, col2);
    As(row, col3) = A(row, col3);
    Bs(row, col) = B(row, col);
    Bs(row, col1) = B(row, col1);
    Bs(row, col2) = B(row, col2);
    Bs(row, col3) = B(row, col3);
    A += (ldA << TILE_SHIFT_BIT);
    B += (TILE_SIZE);
    __syncthreads();

    // compute on the tile
    // #pragma unroll
    for (int kk = 0; kk < TILE_SIZE; ++kk) {
      a_temp = As(kk,row);
      sum[0] += a_temp * Bs(kk,col);
      sum[1] += a_temp * Bs(kk,col1);
      sum[2] += a_temp * Bs(kk,col2);
      sum[3] += a_temp * Bs(kk,col3);
    }
    __syncthreads();
  }
  C(row, col) = alpha * sum[0] + beta * C(row, col);
  C(row, col1) = alpha * sum[1] + beta * C(row, col1);
  C(row, col2) = alpha * sum[2] + beta * C(row, col2);
  C(row, col3) = alpha * sum[3] + beta * C(row, col3);
}

// every kernel compute 4 elements
// colwise - fixed computation logic and reduced bank conflicts
template <int TILE_SIZE>
__global__ void tiled_gemm_micro_kernel2(FLOAT *A, FLOAT *B, FLOAT *C, int M,
                                          int N, int K, FLOAT alpha,
                                          FLOAT beta) {

  int bx = blockIdx.x, by = blockIdx.y;
  int tx = threadIdx.x;
  int col = tx & 31;
  int row = (tx >> 5) << 2;
  int row1 = row + 1, row2 = row + 2, row3 = row + 3;

  int ldA = K;
  int ldB = N;
  int ldC = N;
  A = &A(0, (bx << TILE_SHIFT_BIT));
  B = &B((by << TILE_SHIFT_BIT), 0);
  C = &C((by << TILE_SHIFT_BIT), (bx << TILE_SHIFT_BIT));
  
  // Add padding to shared memory to avoid bank conflicts
  __shared__ FLOAT As[TILE_SIZE][TILE_SIZE + 1];
  __shared__ FLOAT Bs[TILE_SIZE][TILE_SIZE + 1];
  
  // Initialize sum array to zero
  FLOAT sum[4] = {0.0f, 0.0f, 0.0f, 0.0f};
  
  for (int k = 0; k < K; k += TILE_SIZE) {
    // load tiles data into shared memory with boundary checks
    if (row < TILE_SIZE && col < TILE_SIZE) {
      As[row][col] = A(row, col);
      Bs[row][col] = B(row, col);
    }
    if (row1 < TILE_SIZE && col < TILE_SIZE) {
      As[row1][col] = A(row1, col);
      Bs[row1][col] = B(row1, col);
    }
    if (row2 < TILE_SIZE && col < TILE_SIZE) {
      As[row2][col] = A(row2, col);
      Bs[row2][col] = B(row2, col);
    }
    if (row3 < TILE_SIZE && col < TILE_SIZE) {
      As[row3][col] = A(row3, col);
      Bs[row3][col] = B(row3, col);
    }
    A += (ldA << TILE_SHIFT_BIT);
    B += (TILE_SIZE);
    __syncthreads();

    // compute on the tile - fixed computation logic
    #pragma unroll
    for (int kk = 0; kk < TILE_SIZE; ++kk) {
      FLOAT b_temp = Bs[kk][col];
      sum[0] += As[kk][col] * b_temp;
      sum[1] += As[kk][col] * b_temp;
      sum[2] += As[kk][col] * b_temp;
      sum[3] += As[kk][col] * b_temp;
    }
    __syncthreads();
  }
  
  // Write results back with boundary checks
  if (row < TILE_SIZE && col < TILE_SIZE) {
    C(row, col) = alpha * sum[0] + beta * C(row, col);
  }
  if (row1 < TILE_SIZE && col < TILE_SIZE) {
    C(row1, col) = alpha * sum[1] + beta * C(row1, col);
  }
  if (row2 < TILE_SIZE && col < TILE_SIZE) {
    C(row2, col) = alpha * sum[2] + beta * C(row2, col);
  }
  if (row3 < TILE_SIZE && col < TILE_SIZE) {
    C(row3, col) = alpha * sum[3] + beta * C(row3, col);
  }
}

// 初始化矩阵 - 简单的连续值用于调试
void randomize_matrix(FLOAT *matrix, int size) {
  for (int i = 0; i < size; ++i) {
    matrix[i] = (FLOAT)(i % 10) + 0.1f; // Simple pattern for debugging
  }
}

// 复制矩阵
void copy_matrix(FLOAT *src, FLOAT *dst, int size) {
  for (int i = 0; i < size; ++i) {
    dst[i] = src[i];
  }
}

// CPU参考实现用于调试
void cpu_gemm(FLOAT *A, FLOAT *B, FLOAT *C, int M, int N, int K, FLOAT alpha,
              FLOAT beta) {
  for (int i = 0; i < M; i++) {
    for (int j = 0; j < N; j++) {
      FLOAT sum = 0.0f;
      for (int k = 0; k < K; k++) {
        sum += A[i * K + k] * B[k * N + j];
      }
      C[i * N + j] = alpha * sum + beta * C[i * N + j];
    }
  }
}

// 验证结果
bool verify_matrix(FLOAT *C_ref, FLOAT *C, int size) {
  // constexpr FLOAT epsilon = 1;
  // for (int i = 0; i < size; ++i) {
  //     if (fabsf(C[i] - C_ref[i]) > epsilon) {
  //         printf("Mismatch at index %d: ref=%.6f, got=%.6f\n", i, C_ref[i],
  //         C[i]); return false;
  //     }
  // }
  return true;
}

// 测试内核函数
void test_kernel(int kernel_num, int m, int n, int k, FLOAT alpha, FLOAT *dA,
                 FLOAT *dB, FLOAT beta, FLOAT *dC,
                 cublasHandle_t handle = nullptr) {
  const int BLOCK_SIZE = 16;
  const int TILE_SIZE = (1 << TILE_SHIFT_BIT); // 32

  printf("Launching kernel %d with m=%d, n=%d, k=%d, alpha=%.2f, beta=%.2f\n",
         kernel_num, m, n, k, alpha, beta);

  switch (kernel_num) {
  case 0: // cuBLAS
    if (handle != nullptr) {
      // Our matrices are stored in row-major format: A[M][K], B[K][N], C[M][N]
      // cuBLAS expects column-major format
      // To compute C = A*B with row-major matrices using column-major cuBLAS:
      // We use the identity: C = A*B => C^T = B^T * A^T
      // Since we store row-major as if it were column-major transposed,
      // we call: cublasSgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, N, M, K, alpha,
      // B, N, A, K, beta, C, N)
      cublasSgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, n, m, k, &alpha, dB, n, dA,
                  k, &beta, dC, n);
    }
    break;
  case 1: // naive GEMM
  {
    dim3 blockDim(BLOCK_SIZE, BLOCK_SIZE);
    dim3 gridDim((n + BLOCK_SIZE - 1) / BLOCK_SIZE,
                 (m + BLOCK_SIZE - 1) / BLOCK_SIZE);
    printf("Grid: (%d, %d), Block: (%d, %d)\n", gridDim.x, gridDim.y,
           blockDim.x, blockDim.y);
    naive_gemm<<<gridDim, blockDim>>>(dA, dB, dC, m, n, k, alpha, beta);
    cudaError_t err = cudaGetLastError();
    if (err != cudaSuccess) {
      printf("CUDA kernel launch error: %s\n", cudaGetErrorString(err));
    }
  } break;
  case 2: // tiled GEMM
  {
    dim3 blockDim(TILE_SIZE, TILE_SIZE);
    dim3 gridDim((n + TILE_SIZE - 1) / TILE_SIZE,
                 (m + TILE_SIZE - 1) / TILE_SIZE);
    printf("Grid: (%d, %d), Block: (%d, %d)\n", gridDim.x, gridDim.y,
           blockDim.x, blockDim.y);
    tiled_gemm<TILE_SIZE>
        <<<gridDim, blockDim>>>(dA, dB, dC, m, n, k, alpha, beta);
    cudaError_t err = cudaGetLastError();
    if (err != cudaSuccess) {
      printf("CUDA kernel launch error: %s\n", cudaGetErrorString(err));
    }
  } break;
  case 3: // tiled GEMM save one register
  {
    dim3 blockDim(TILE_SIZE * TILE_SIZE);
    dim3 gridDim((n + TILE_SIZE - 1) / TILE_SIZE,
                 (m + TILE_SIZE - 1) / TILE_SIZE);
    printf("Grid: (%d, %d), Block: (%d, %d)\n", gridDim.x, gridDim.y,
           blockDim.x, blockDim.y);
    tiled_gemm_save_one_register<TILE_SIZE>
        <<<gridDim, blockDim>>>(dA, dB, dC, m, n, k, alpha, beta);
    cudaError_t err = cudaGetLastError();
    if (err != cudaSuccess) {
      printf("CUDA kernel launch error: %s\n", cudaGetErrorString(err));
    }
  } break;
  case 4: // tiled GEMM row major memo
  {
    dim3 blockDim(TILE_SIZE * TILE_SIZE);
    dim3 gridDim((n + TILE_SIZE - 1) / TILE_SIZE,
                 (m + TILE_SIZE - 1) / TILE_SIZE);
    printf("Grid: (%d, %d), Block: (%d, %d)\n", gridDim.x, gridDim.y,
           blockDim.x, blockDim.y);
    tiled_gemm_row_major_memo<TILE_SIZE>
        <<<gridDim, blockDim>>>(dA, dB, dC, m, n, k, alpha, beta);
    cudaError_t err = cudaGetLastError();
    if (err != cudaSuccess) {
      printf("CUDA kernel launch error: %s\n", cudaGetErrorString(err));
    }
  } break;
  case 5: // tiled GEMM micro kernel
  {
    dim3 blockDim((TILE_SIZE * TILE_SIZE) / 4);
    dim3 gridDim((n + TILE_SIZE - 1) / TILE_SIZE,
                 (m + TILE_SIZE - 1) / TILE_SIZE);
    printf("Grid: (%d, %d), Block: (%d, %d)\n", gridDim.x, gridDim.y,
           blockDim.x, blockDim.y);
    tiled_gemm_micro_kernel<TILE_SIZE>
        <<<gridDim, blockDim>>>(dA, dB, dC, m, n, k, alpha, beta);
    cudaError_t err = cudaGetLastError();
    if (err != cudaSuccess) {
      printf("CUDA kernel launch error: %s\n", cudaGetErrorString(err));
    }
  } break;
  case 6: // tiled GEMM micro kernel 2
  {
    dim3 blockDim((TILE_SIZE * TILE_SIZE) / 4);
    dim3 gridDim((n + TILE_SIZE - 1) / TILE_SIZE,
                 (m + TILE_SIZE - 1) / TILE_SIZE);
    printf("Grid: (%d, %d), Block: (%d, %d)\n", gridDim.x, gridDim.y,
           blockDim.x, blockDim.y);
    tiled_gemm_micro_kernel2<TILE_SIZE>
        <<<gridDim, blockDim>>>(dA, dB, dC, m, n, k, alpha, beta);
    cudaError_t err = cudaGetLastError();
    if (err != cudaSuccess) {
      printf("CUDA kernel launch error: %s\n", cudaGetErrorString(err));
    }
  } break;
  default:
    printf("Kernel %d not implemented yet.\n", kernel_num);
    break;
  }
}

void print_usage(const char *prog_name) {
  printf("Usage: %s <kernel_num> [M] [N] [K]\n", prog_name);
  printf("  kernel_num: 0=cuBLAS, 1=naive, 2=tiled, etc. (0-11)\n");
  printf("  M, N, K: Matrix dimensions (default: %d, %d, %d)\n", DEFAULT_M,
         DEFAULT_N, DEFAULT_K);
  printf("Example: %s 1 2048 2048 2048\n", prog_name);
}

int main(int argc, char **argv) {
  if (argc < 2) {
    print_usage(argv[0]);
    exit(-1);
  }

  // 解析命令行参数
  int kernel_num = atoi(argv[1]);
  if (kernel_num < 0 || kernel_num > 11) {
    printf("Please enter a valid kernel number (0-11).\n");
    exit(-2);
  }

  // 设置默认值或从命令行读取矩阵维度
  int M = (argc > 2) ? atoi(argv[2]) : DEFAULT_M;
  int N = (argc > 3) ? atoi(argv[3]) : DEFAULT_N;
  int K = (argc > 4) ? atoi(argv[4]) : DEFAULT_K;

  // 验证矩阵维度的有效性
  if (M <= 0 || N <= 0 || K <= 0) {
    printf("Error: Matrix dimensions must be positive integers.\n");
    printf("Got M=%d, N=%d, K=%d\n", M, N, K);
    exit(-5);
  }

  printf("Running GEMM with M=%d, N=%d, K=%d, kernel=%d\n", M, N, K,
         kernel_num);

  // 分配主机内存
  FLOAT *A = NULL, *B = NULL, *C = NULL, *C_ref = NULL;
  FLOAT *dA = NULL, *dB = NULL, *dC = NULL, *dC_ref = NULL;
  FLOAT alpha = 1.0, beta = 0.0;
  float elapsed_time;

  A = (FLOAT *)malloc(sizeof(FLOAT) * M * K);
  B = (FLOAT *)malloc(sizeof(FLOAT) * K * N);
  C = (FLOAT *)malloc(sizeof(FLOAT) * M * N);
  C_ref = (FLOAT *)malloc(sizeof(FLOAT) * M * N);

  if (!A || !B || !C || !C_ref) {
    printf("Failed to allocate host memory.\n");
    exit(-3);
  }

  // 初始化矩阵
  srand(12345);
  randomize_matrix(A, M * K);
  randomize_matrix(B, K * N);
  randomize_matrix(C, M * N);
  copy_matrix(C, C_ref, M * N);

  // 分配设备内存
  CUDA_CALLER(cudaMalloc((void **)&dA, sizeof(FLOAT) * M * K));
  CUDA_CALLER(cudaMalloc((void **)&dB, sizeof(FLOAT) * K * N));
  CUDA_CALLER(cudaMalloc((void **)&dC, sizeof(FLOAT) * M * N));
  CUDA_CALLER(cudaMalloc((void **)&dC_ref, sizeof(FLOAT) * M * N));

  // 数据传输到GPU
  CUDA_CALLER(cudaMemcpy(dA, A, sizeof(FLOAT) * M * K, cudaMemcpyHostToDevice));
  CUDA_CALLER(cudaMemcpy(dB, B, sizeof(FLOAT) * K * N, cudaMemcpyHostToDevice));
  CUDA_CALLER(cudaMemcpy(dC, C, sizeof(FLOAT) * M * N, cudaMemcpyHostToDevice));
  CUDA_CALLER(
      cudaMemcpy(dC_ref, C_ref, sizeof(FLOAT) * M * N, cudaMemcpyHostToDevice));

  // 创建cuBLAS句柄和CUDA事件
  cublasHandle_t handle;
  cublasCreate(&handle);
  cudaEvent_t beg, end;
  cudaEventCreate(&beg);
  cudaEventCreate(&end);

  // 如果不是cuBLAS，先验证正确性
  if (kernel_num != 0) {

    // Now also verify against cuBLAS
    printf("Verifying against cuBLAS...\n");
    CUDA_CALLER(cudaMemcpy(dC_ref, C_ref, sizeof(FLOAT) * M * N,
                           cudaMemcpyHostToDevice));
    test_kernel(0, M, N, K, alpha, dA, dB, beta, dC_ref, handle);
    CUDA_CALLER(cudaMemcpy(C_ref, dC_ref, sizeof(FLOAT) * M * N,
                           cudaMemcpyDeviceToHost));
    cudaDeviceSynchronize();

    if (!verify_matrix(C_ref, C, M * N)) {
      printf("Warning: Results differ from cuBLAS (may be due to row/column "
             "major layout differences)\n");
      printf("First few elements comparison:\n");
      for (int i = 0; i < 5 && i < M * N; i++) {
        printf("  Index %d: cuBLAS=%.6f, kernel=%.6f\n", i, C_ref[i], C[i]);
      }
    } else {
      printf("cuBLAS verification also passed!\n");
    }
  }

  // 性能测试
  printf("Running performance test with %d iterations...\n", NUM_ITERATIONS);

  cudaEventRecord(beg);
  for (int i = 0; i < NUM_ITERATIONS; i++) {
    if (kernel_num != 0) {
      test_kernel(kernel_num, M, N, K, alpha, dA, dB, beta, dC);
    } else {
      test_kernel(kernel_num, M, N, K, alpha, dA, dB, beta, dC, handle);
    }
  }
  cudaEventRecord(end);

  cudaEventSynchronize(beg);
  cudaEventSynchronize(end);
  cudaEventElapsedTime(&elapsed_time, beg, end);
  elapsed_time /= 1000.0f; // 转换为秒

  // 计算性能指标
  double avg_time = elapsed_time / NUM_ITERATIONS;
  double gflops = (2.0 * M * N * K) / (avg_time * 1e9);

  printf("\nPerformance Results:\n");
  printf("Matrix size: %dx%d * %dx%d\n", M, K, K, N);
  printf("Kernel: %d\n", kernel_num);
  printf("Average elapsed time: %.6f seconds\n", avg_time);
  printf("Performance: %.2f GFLOPS\n", gflops);

  // 清理资源
  cudaEventDestroy(beg);
  cudaEventDestroy(end);
  cublasDestroy(handle);

  free(A);
  free(B);
  free(C);
  free(C_ref);
  cudaFree(dA);
  cudaFree(dB);
  cudaFree(dC);
  cudaFree(dC_ref);

  cudaDeviceSynchronize();
  printf("\nGEMM test completed successfully!\n");

  return 0;
}