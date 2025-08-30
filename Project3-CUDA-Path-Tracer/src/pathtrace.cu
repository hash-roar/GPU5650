#include "pathtrace.h"

#include <cstdio>
#include <cuda.h>
#include <cmath>
#include <thrust/execution_policy.h>
#include <thrust/random.h>
#include <thrust/remove.h>
#include <thrust/partition.h>
#include <thrust/sort.h>
#include <thrust/device_vector.h>
#include <thrust/sequence.h>
#include <thrust/gather.h>
#include <thrust/count.h>
#include <thrust/transform.h>
#include <thrust/device_ptr.h>
#include <thrust/iterator/zip_iterator.h>
#include <thrust/tuple.h>

#include "sceneStructs.h"
#include "scene.h"
#include "../external/include/glm/glm.hpp"
#include "glm/glm.hpp"
#include "glm/gtx/norm.hpp"
#include "utilities.h"
#include "intersections.h"
#include "interactions.h"

#if defined(__INTELLISENSE__) && !defined(__CUDACC__)
#define __CUDACC__
#define __CUDACC_VER_MAJOR__ 11
#define __CUDACC_VER_MINOR__ 0
#include <cuda_runtime.h>
#include <device_launch_parameters.h>
#undef __CUDACC__
#define <<<...>>> 
#endif

#define ERRORCHECK 1

#define FILENAME (strrchr(__FILE__, '/') ? strrchr(__FILE__, '/') + 1 : __FILE__)
#define checkCUDAError(msg) checkCUDAErrorFn(msg, FILENAME, __LINE__)
void checkCUDAErrorFn(const char* msg, const char* file, int line)
{
#if ERRORCHECK
    cudaDeviceSynchronize();
    cudaError_t err = cudaGetLastError();
    if (cudaSuccess == err)
    {
        return;
    }

    fprintf(stderr, "CUDA error");
    if (file)
    {
        fprintf(stderr, " (%s:%d)", file, line);
    }
    fprintf(stderr, ": %s: %s\n", msg, cudaGetErrorString(err));
#ifdef _WIN32
    getchar();
#endif // _WIN32
    exit(EXIT_FAILURE);
#endif // ERRORCHECK
}

__host__ __device__
thrust::default_random_engine makeSeededRandomEngine(int iter, int index, int depth)
{
    int h = utilhash((1 << 31) | (depth << 22) | iter) ^ utilhash(index);
    return thrust::default_random_engine(h);
}

//Kernel that writes the image to the OpenGL PBO directly.
__global__ void sendImageToPBO(uchar4* pbo, glm::ivec2 resolution, int iter, glm::vec3* image)
{
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;



    if (x < resolution.x && y < resolution.y)
    {
        int index = x + (y * resolution.x);
        glm::vec3 pix = image[index];

        glm::ivec3 color;
        color.x = glm::clamp((int)(pix.x / iter * 255.0), 0, 255);
        color.y = glm::clamp((int)(pix.y / iter * 255.0), 0, 255);
        color.z = glm::clamp((int)(pix.z / iter * 255.0), 0, 255);

        // Each thread writes one pixel location in the texture (textel)
        pbo[index].w = 0;
        pbo[index].x = color.x;
        pbo[index].y = color.y;
        pbo[index].z = color.z;
    }
}

static Scene* hst_scene = nullptr;
static GuiDataContainer* guiData = nullptr;
static glm::vec3* dev_image = nullptr;
static Geom* dev_geoms = nullptr;
static Material* dev_materials = nullptr;
static PathSegment* dev_paths = nullptr;
static ShadeableIntersection* dev_intersections = nullptr;

// Performance toggles
static bool USE_STREAM_COMPACTION = true;
static bool SORT_BY_MATERIAL = false;

void InitDataContainer(GuiDataContainer* imGuiData)
{
    guiData = imGuiData;
}

// Performance control functions
void toggleStreamCompaction() {
    USE_STREAM_COMPACTION = !USE_STREAM_COMPACTION;
    printf("Stream Compaction: %s\n", USE_STREAM_COMPACTION ? "ON" : "OFF");
}

void toggleMaterialSorting() {
    SORT_BY_MATERIAL = !SORT_BY_MATERIAL;
    printf("Material Sorting: %s\n", SORT_BY_MATERIAL ? "ON" : "OFF");
}

bool getStreamCompactionStatus() {
    return USE_STREAM_COMPACTION;
}

bool getMaterialSortingStatus() {
    return SORT_BY_MATERIAL;
}

void pathtraceInit(Scene* scene)
{
    hst_scene = scene;

    const Camera& cam = hst_scene->state.camera;
    const int pixelcount = cam.resolution.x * cam.resolution.y;

    cudaMalloc(&dev_image, pixelcount * sizeof(glm::vec3));
    cudaMemset(dev_image, 0, pixelcount * sizeof(glm::vec3));

    cudaMalloc(&dev_paths, pixelcount * sizeof(PathSegment));

    cudaMalloc(&dev_geoms, scene->geoms.size() * sizeof(Geom));
    cudaMemcpy(dev_geoms, scene->geoms.data(), scene->geoms.size() * sizeof(Geom), cudaMemcpyHostToDevice);

    cudaMalloc(&dev_materials, scene->materials.size() * sizeof(Material));
    cudaMemcpy(dev_materials, scene->materials.data(), scene->materials.size() * sizeof(Material), cudaMemcpyHostToDevice);

    cudaMalloc(&dev_intersections, pixelcount * sizeof(ShadeableIntersection));
    cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

    checkCUDAError("pathtraceInit");
}

void pathtraceFree()
{
    cudaFree(dev_image);  // no-op if dev_image is null
    cudaFree(dev_paths);
    cudaFree(dev_geoms);
    cudaFree(dev_materials);
    cudaFree(dev_intersections);

    checkCUDAError("pathtraceFree");
}

/**
* Generate PathSegments with rays from the camera through the screen into the
* scene, which is the first bounce of rays.
*
* Antialiasing - add rays for sub-pixel sampling
* motion blur - jitter rays "in time"
* lens effect - jitter ray origin positions based on a lens
*/
__global__ void generateRayFromCamera(Camera cam, int iter, int traceDepth, PathSegment* pathSegments)
{
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;

    if (x < cam.resolution.x && y < cam.resolution.y) {
        int index = x + (y * cam.resolution.x);
        PathSegment& segment = pathSegments[index];

        segment.ray.origin = cam.position;
        segment.color = glm::vec3(0.0f, 0.0f, 0.0f);         // No light contribution initially
        segment.throughput = glm::vec3(1.0f, 1.0f, 1.0f);    // Full throughput initially

        // TODO: implement antialiasing by jittering the ray
        segment.ray.direction = glm::normalize(cam.view
            - cam.right * cam.pixelLength.x * ((float)x - (float)cam.resolution.x * 0.5f)
            - cam.up * cam.pixelLength.y * ((float)y - (float)cam.resolution.y * 0.5f)
        );

        segment.pixelIndex = index;
        segment.remainingBounces = traceDepth;
    }
}

// TODO:
// computeIntersections handles generating ray intersections ONLY.
// Generating new rays is handled in your shader(s).
// Feel free to modify the code below.
__global__ void computeIntersections(
    int depth,
    int num_paths,
    PathSegment* pathSegments,
    Geom* geoms,
    int geoms_size,
    ShadeableIntersection* intersections)
{
    int path_index = blockIdx.x * blockDim.x + threadIdx.x;

    if (path_index < num_paths)
    {
        PathSegment pathSegment = pathSegments[path_index];

        float t;
        glm::vec3 intersect_point;
        glm::vec3 normal;
        float t_min = FLT_MAX;
        int hit_geom_index = -1;
        bool outside = true;

        glm::vec3 tmp_intersect;
        glm::vec3 tmp_normal;

        // naive parse through global geoms

        for (int i = 0; i < geoms_size; i++)
        {
            Geom& geom = geoms[i];

            if (geom.type == CUBE)
            {
                t = boxIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
            }
            else if (geom.type == SPHERE)
            {
                t = sphereIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
            }
            // TODO: add more intersection tests here... triangle? metaball? CSG?

            // Compute the minimum t from the intersection tests to determine what
            // scene geometry object was hit first.
            if (t > 0.0f && t_min > t)
            {
                t_min = t;
                hit_geom_index = i;
                intersect_point = tmp_intersect;
                normal = tmp_normal;
            }
        }

        if (hit_geom_index == -1)
        {
            intersections[path_index].t = -1.0f;
        }
        else
        {
            // The ray hits something
            intersections[path_index].t = t_min;
            intersections[path_index].materialId = geoms[hit_geom_index].materialid;
            intersections[path_index].surfaceNormal = normal;
        }
    }
}

// Predicate function for stream compaction to remove terminated paths
struct PathTerminationPredicate
{
    __host__ __device__
    bool operator()(const PathSegment& path)
    {
        return path.remainingBounces > 0;
    }
};

// Predicate function to check if path has valid intersection
struct PathIntersectionPredicate
{
    ShadeableIntersection* intersections;
    
    __host__ __device__
    PathIntersectionPredicate(ShadeableIntersection* _intersections) : intersections(_intersections) {}
    
    __host__ __device__
    bool operator()(int index)
    {
        return intersections[index].t > 0.0f;
    }
};

// Predicate to check if intersection is invalid (for removal)
struct InvalidIntersectionPredicate
{
    ShadeableIntersection* intersections;
    
    __host__ __device__
    InvalidIntersectionPredicate(ShadeableIntersection* _intersections) : intersections(_intersections) {}
    
    __host__ __device__
    bool operator()(int index)
    {
        return intersections[index].t <= 0.0f;
    }
};

// Functor to extract material ID from an intersection object
struct GetMaterialId {
    __host__ __device__
    int operator()(const ShadeableIntersection& inter) const {
        // For invalid intersections (t <= 0), use a special high value to sort them last
        return (inter.t > 0.0f) ? inter.materialId : INT_MAX;
    }
};

// BSDF shader with throughput logic and direct image accumulation
__global__ void shadeBSDF(
    int iter,
    int num_paths,
    ShadeableIntersection* shadeableIntersections,
    PathSegment* pathSegments,
    Material* materials,
    glm::vec3* image)
{
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < num_paths)
    {
        ShadeableIntersection intersection = shadeableIntersections[idx];
        PathSegment& pathSegment = pathSegments[idx];
        
        // Check if path should continue
        if (pathSegment.remainingBounces <= 0 || intersection.t <= 0.0f) {
            pathSegment.remainingBounces = 0;
            return;
        }
        
        if (intersection.t > 0.0f) // if the intersection exists...
        {
            // Set up the RNG
            thrust::default_random_engine rng = makeSeededRandomEngine(iter, idx, pathSegment.remainingBounces);
            
            Material material = materials[intersection.materialId];
            glm::vec3 intersectionPoint = getPointOnRay(pathSegment.ray, intersection.t);
            
            // Check if we hit a light source
            if (material.emittance > 0.0f) {
                // Accumulate light contribution directly to image
                glm::vec3 lightContribution = pathSegment.throughput * material.color * material.emittance;
                pathSegment.color = lightContribution;
                image[pathSegment.pixelIndex] += lightContribution;
                // Terminate path
                pathSegment.remainingBounces = 0;
            } else {
                // Non-emissive material - scatter ray and update throughput
                pathSegment.color = glm::vec3(0.0f); // No light contribution this bounce
                
                // Scatter the ray based on BSDF
                scatterRay(pathSegment, intersectionPoint, intersection.surfaceNormal, material, rng);
            }
        }
        else {
            // Ray hit background - terminate
            pathSegment.color = glm::vec3(0.0f);
            pathSegment.remainingBounces = 0;
        }
    }
}

// Gather terminated paths for current bounce (used in material sorting workflow)
__global__ void gatherTerminatedPaths(int num_paths, glm::vec3* image, PathSegment* paths)
{
    int index = (blockIdx.x * blockDim.x) + threadIdx.x;

    if (index < num_paths)
    {
        PathSegment& path = paths[index];
        // Only gather paths that have terminated and have color contribution
        if (path.remainingBounces <= 0 && (path.color.x > 0.0f || path.color.y > 0.0f || path.color.z > 0.0f))
        {
            image[path.pixelIndex] += path.color;
        }
    }
}

// Add the current iteration's output to the overall image
__global__ void finalGather(int nPaths, glm::vec3* image, PathSegment* iterationPaths)
{
    int index = (blockIdx.x * blockDim.x) + threadIdx.x;

    if (index < nPaths)
    {
        PathSegment iterationPath = iterationPaths[index];
        image[iterationPath.pixelIndex] += iterationPath.color;
    }
}

/**
 * Wrapper for the __global__ call that sets up the kernel calls and does a ton
 * of memory management
 */
void pathtrace(uchar4* pbo, int frame, int iter)
{
    const int traceDepth = hst_scene->state.traceDepth;
    const Camera& cam = hst_scene->state.camera;
    const int pixelcount = cam.resolution.x * cam.resolution.y;

    // Update GUI data at start of iteration
    if (guiData != nullptr)
    {
        guiData->CurrentIteration = iter;
        guiData->TotalPaths = pixelcount;
        guiData->MaxTracedDepth = 0; // Reset for this iteration
        guiData->StreamCompactionEnabled = USE_STREAM_COMPACTION;
        guiData->MaterialSortingEnabled = SORT_BY_MATERIAL;
    }

    // 2D block for generating ray from camera
    const dim3 blockSize2d(8, 8);
    const dim3 blocksPerGrid2d(
        (cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
        (cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

    // 1D block for path tracing
    const int blockSize1d = 128;

    ///////////////////////////////////////////////////////////////////////////

    // Recap:
    // * Initialize array of path rays (using rays that come out of the camera)
    //   * You can pass the Camera object to that kernel.
    //   * Each path ray must carry at minimum a (ray, color) pair,
    //   * where color starts as the multiplicative identity, white = (1, 1, 1).
    //   * This has already been done for you.
    // * For each depth:
    //   * Compute an intersection in the scene for each path ray.
    //     A very naive version of this has been implemented for you, but feel
    //     free to add more primitives and/or a better algorithm.
    //     Currently, intersection distance is recorded as a parametric distance,
    //     t, or a "distance along the ray." t = -1.0 indicates no intersection.
    //     * Color is attenuated (multiplied) by reflections off of any object
    //   * TODO: Stream compact away all of the terminated paths.
    //     You may use either your implementation or `thrust::remove_if` or its
    //     cousins.
    //     * Note that you can't really use a 2D kernel launch any more - switch
    //       to 1D.
    //   * TODO: Shade the rays that intersected something or didn't bottom out.
    //     That is, color the ray by performing a color computation according
    //     to the shader, then generate a new ray to continue the ray path.
    //     We recommend just updating the ray's PathSegment in place.
    //     Note that this step may come before or after stream compaction,
    //     since some shaders you write may also cause a path to terminate.
    // * Finally, add this iteration's results to the image. This has been done
    //   for you.

    // TODO: perform one iteration of path tracing

    generateRayFromCamera<<<blocksPerGrid2d, blockSize2d>>>(cam, iter, traceDepth, dev_paths);
    checkCUDAError("generate camera ray");

    int depth = 0;
    PathSegment* dev_path_end = dev_paths + pixelcount;
    int num_paths = dev_path_end - dev_paths;

    // --- PathSegment Tracing Stage ---
    // Shoot ray into scene, bounce between objects, push shading chunks

    bool iterationComplete = false;
    while (!iterationComplete)
    {
        // clean shading chunks
        cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

        // tracing
        dim3 numblocksPathSegmentTracing = (num_paths + blockSize1d - 1) / blockSize1d;
        computeIntersections<<<numblocksPathSegmentTracing, blockSize1d>>> (
            depth,
            num_paths,
            dev_paths,
            dev_geoms,
            hst_scene->geoms.size(),
            dev_intersections
        );
        checkCUDAError("trace one bounce");
        cudaDeviceSynchronize();
        depth++;



        // Material sorting for better coherence (optional optimization)
        PathSegment* paths_to_shade = dev_paths;
        ShadeableIntersection* intersections_to_shade = dev_intersections;
        
        if (SORT_BY_MATERIAL && num_paths > 0) {
            // 1. 创建一个 device_vector 来存储 Key (Material IDs)
            thrust::device_vector<int> material_ids(num_paths);

            // 2. 从 dev_intersections 中提取 material_id 到新的 vector 中
            thrust::transform(thrust::device_pointer_cast(dev_intersections),
                              thrust::device_pointer_cast(dev_intersections) + num_paths,
                              material_ids.begin(),
                              GetMaterialId());
            
            // 3. 将两个需要排序的 Value 数组打包成一个 zip_iterator
            auto values_begin = thrust::make_zip_iterator(
                thrust::make_tuple(
                    thrust::device_pointer_cast(dev_paths),
                    thrust::device_pointer_cast(dev_intersections)
                )
            );

            // 4. 执行一步到位的 "sort by key"
            thrust::stable_sort_by_key(
                material_ids.begin(), // Keys to sort by
                material_ids.end(),
                values_begin          // Zipped values to sort
            );

            checkCUDAError("thrust::stable_sort_by_key");
            cudaDeviceSynchronize();

            // 现在 dev_paths 和 dev_intersections 已经按 material_id 排序好了
            paths_to_shade = dev_paths;
            intersections_to_shade = dev_intersections;
        }

        // Shading Stage - Shade path segments and accumulate light contributions
        shadeBSDF<<<numblocksPathSegmentTracing, blockSize1d>>>(
            iter,
            num_paths,
            intersections_to_shade,
            paths_to_shade,
            dev_materials,
            dev_image  // Pass image for direct accumulation
        );
        checkCUDAError("shade bsdf");
        cudaDeviceSynchronize();

        // Second stream compaction: remove terminated paths for next iteration
        if (USE_STREAM_COMPACTION) {
            PathSegment* new_end = thrust::stable_partition(
                thrust::device,
                dev_paths,
                dev_paths + num_paths,
                PathTerminationPredicate()
            );
            
            num_paths = new_end - dev_paths;
        } else {
            // Count remaining paths without compaction
            int remaining = thrust::count_if(
                thrust::device,
                dev_paths,
                dev_paths + num_paths,
                PathTerminationPredicate()
            );
            
            // If no paths remain, we can terminate
            if (remaining == 0) {
                num_paths = 0;
            }
        }

        // Check if all paths are terminated or max depth reached
        iterationComplete = (num_paths == 0) || (depth >= traceDepth);

        // Update GUI data for current depth
        if (guiData != nullptr)
        {
            guiData->TracedDepth = depth;
            guiData->ActivePaths = num_paths;
            if (depth > guiData->MaxTracedDepth) {
                guiData->MaxTracedDepth = depth;
            }
        }

    }

    // All light contributions have been accumulated directly in the shader
    // No need for final gather since we use throughput approach

    ///////////////////////////////////////////////////////////////////////////

    // Send results to OpenGL buffer for rendering
    sendImageToPBO<<<blocksPerGrid2d, blockSize2d>>>(pbo, cam.resolution, iter, dev_image);

    // Retrieve image from GPU
    cudaMemcpy(hst_scene->state.image.data(), dev_image,
        pixelcount * sizeof(glm::vec3), cudaMemcpyDeviceToHost);

    checkCUDAError("pathtrace");
}
