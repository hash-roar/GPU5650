#include <cstdio>
#include "cpu.h"

#include "common.h"

namespace StreamCompaction {
    namespace CPU {
        using StreamCompaction::Common::PerformanceTimer;
        PerformanceTimer& timer()
        {
            static PerformanceTimer timer;
            return timer;
        }

        /**
         * CPU scan (prefix sum).
         * For performance analysis, this is supposed to be a simple for loop.
         * (Optional) For better understanding before starting moving to GPU, you can simulate your GPU scan in this function first.
         */
        void scan(int n, int *odata, const int *idata) {
            if (n <= 0) {
                return; // Handle empty input
            
            }
            timer().startCpuTimer();
            // exclusive scan
            odata[0] = 0; // The first element is always 0 in exclusive scan
            for (int i = 1; i < n; ++i) {
                odata[i] = odata[i - 1] + idata[i - 1];
            }
            timer().endCpuTimer();
        }

        /**
         * CPU stream compaction without using the scan function.
         *
         * @returns the number of elements remaining after compaction.
         */
        int compactWithoutScan(int n, int *odata, const int *idata) {
            if (n <= 0) {
                return 0; // Handle empty input
            }
            timer().startCpuTimer();
            int count = 0;
            for (int i = 0; i < n; ++i) {
                if (idata[i] != 0) { // Assuming we want to compact non-zero elements
                    odata[count++] = idata[i];
                }
            }
            timer().endCpuTimer();
            return count;
        }

        /**
         * CPU stream compaction using scan and scatter, like the parallel version.
         *
         * @returns the number of elements remaining after compaction.
         */
        int compactWithScan(int n, int *odata, const int *idata) {
            timer().startCpuTimer();
            // Step 1: Perform exclusive scan on the input data
            int *scan_buf = new int[n];
            scan(n, scan_buf, idata);
            // Step 2: Scatter the input data based on the scan results
            for (int i = 0; i < n; ++i) {
                if (idata[i] != 0) {
                    odata[scan_buf[i]] = idata[i];
                }
            }
            delete[] scan_buf;
            timer().endCpuTimer();
            return scan_buf[n - 1] + (idata[n - 1] != 0 ? 1 : 0); // Return the count of non-zero elements
        }
    }
}
