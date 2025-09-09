#include <algorithm>
#include <chrono>
#include <cstdio>
inline float get_seconds_now() {
  using namespace std::chrono;
  return duration_cast<duration<float>>(steady_clock::now().time_since_epoch())
      .count();
}

template <int M, int N, int K>
void cpu_gemm_naive(const float *A, const float *B, float *C) {
  for (int m = 0; m < M; ++m) {
    for (int n = 0; n < N; ++n) {
      float sum = 0.0f;
      for (int k = 0; k < K; ++k) {
        sum += A[m * K + k] * B[k * N + n];
      }
      C[m * N + n] = sum;
    }
  }
}

template <int M, int N, int K>
void cpu_gemm_cached(const float *A, const float *B, float *C) {
  for (int m = 0; m < M; ++m) {
    for (int k = 0; k < K; ++k) {
      for (int n = 0; n < N; ++n) {
        C[m * N + n] += A[m * K + k] * B[k * N + n];
      }
    }
  }
}

template <int M, int N, int K, int TileSize>
void cpu_gemm_cached_tiled1D(const float *A, const float *B, float *C) {
  for (int tile = 0; tile < K; tile += TileSize) {
    for (int m = 0; m < M; ++m) {
      for (int k = tile; k < tile + TileSize; ++k) {
        for (int n = 0; n < N; ++n) {
          C[m * N + n] += A[m * K + k] * B[k * N + n];
        }
      }
    }
  }
}

template <int M, int N, int K, int TileSize>
void cpu_gemm_cached_tiled2D(const float *A, const float *B, float *C) {
  for (int row_tile = 0; row_tile < M; row_tile += TileSize) {
    for (int col_tile = 0; col_tile < N; col_tile += TileSize) {
      for (int k = 0; k < K; ++k) {
        for (int m = row_tile; m < row_tile + TileSize ; ++m) {
          for (int n = col_tile; n < col_tile + TileSize ; ++n) {
            C[m * N + n] += A[m * K + k] * B[k * N + n];
          }
        }
      }
    }
  }
}

int main() {
  const int M = 4096;
  const int N = 4096;
  const int K = 1024;
  const int iterations = 2;

  float *A = new float[M * K];
  float *B = new float[K * N];
  float *C = new float[M * N];

  std::fill_n(C, M * N, 0.0f);
  // Initialize A and B with some values
  for (int i = 0; i < M * K; ++i)
    A[i] = static_cast<float>(i);
  for (int i = 0; i < K * N; ++i)
    B[i] = static_cast<float>(i);
  auto now = get_seconds_now();
  // cpu_gemm<M, N, K>(A, B, C);
  // for(int i = 0; i < iterations; ++i){
  //     cpu_gemm_naive<M, N, K>(A, B, C);
  // }
  auto elapsed = get_seconds_now() - now;
  printf("Naive Implementation Elapsed time: %.4f seconds\n",
         elapsed / iterations);
  std::fill_n(C, M * N, 0.0f);
  now = get_seconds_now();
  for (int i = 0; i < iterations; ++i) {
    cpu_gemm_cached<M, N, K>(A, B, C);
  }
  elapsed = get_seconds_now() - now;
  printf("Cached Implementation Elapsed time: %.4f seconds\n",
         elapsed / iterations);
  std::fill_n(C, M * N, 0.0f);
  now = get_seconds_now();
  for (int i = 0; i < iterations; ++i) {
    cpu_gemm_cached_tiled1D<M, N, K, 32>(A, B, C);
  }
  elapsed = get_seconds_now() - now;
  printf("Cached Tiled 1D Implementation Elapsed time: %.4f seconds\n",
         elapsed / iterations);
  std::fill_n(C, M * N, 0.0f);
  now = get_seconds_now();
  for (int i = 0; i < iterations; ++i) {
    cpu_gemm_cached_tiled2D<M, N, K, 256>(A, B, C);
  }
  elapsed = get_seconds_now() - now;
    printf("Cached Tiled 2D Implementation Elapsed time: %.4f seconds\n",
         elapsed / iterations);
  // Clean up
  delete[] A;
  delete[] B;
  delete[] C;

  return 0;
}