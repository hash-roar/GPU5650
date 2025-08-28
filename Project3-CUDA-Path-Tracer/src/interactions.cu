#include "interactions.h"

__host__ __device__ glm::vec3 calculateRandomDirectionInHemisphere(
    glm::vec3 normal,
    thrust::default_random_engine &rng)
{
    thrust::uniform_real_distribution<float> u01(0, 1);

    float up = sqrt(u01(rng)); // cos(theta)
    float over = sqrt(1 - up * up); // sin(theta)
    float around = u01(rng) * TWO_PI;

    // Find a direction that is not the normal based off of whether or not the
    // normal's components are all equal to sqrt(1/3) or whether or not at
    // least one component is less than sqrt(1/3). Learned this trick from
    // Peter Kutz.

    glm::vec3 directionNotNormal;
    if (abs(normal.x) < SQRT_OF_ONE_THIRD)
    {
        directionNotNormal = glm::vec3(1, 0, 0);
    }
    else if (abs(normal.y) < SQRT_OF_ONE_THIRD)
    {
        directionNotNormal = glm::vec3(0, 1, 0);
    }
    else
    {
        directionNotNormal = glm::vec3(0, 0, 1);
    }

    // Use not-normal direction to generate two perpendicular directions
    glm::vec3 perpendicularDirection1 =
        glm::normalize(glm::cross(normal, directionNotNormal));
    glm::vec3 perpendicularDirection2 =
        glm::normalize(glm::cross(normal, perpendicularDirection1));

    return up * normal
        + cos(around) * over * perpendicularDirection1
        + sin(around) * over * perpendicularDirection2;
}

__host__ __device__ void scatterRay(
    PathSegment & pathSegment,
    glm::vec3 intersect,
    glm::vec3 normal,
    const Material &m,
    thrust::default_random_engine &rng)
{
    thrust::uniform_real_distribution<float> u01(0, 1);
    
    // Note: Emissive materials are now handled in the main shader
    // This function only handles scattering for non-emissive materials
    
    // Simple material handling - check material types
    bool isDiffuse = (m.hasReflective < 0.5f && m.hasRefractive < 0.5f);
    bool isSpecular = (m.hasReflective > 0.5f);
    bool isRefractive = (m.hasRefractive > 0.5f);
    
    // For simplicity, use 50/50 split if multiple material types
    float choice = u01(rng);
    
    if (isDiffuse || (!isSpecular && !isRefractive)) {
        // Diffuse BSDF - multiply throughput by material color
        pathSegment.throughput *= m.color;
        pathSegment.ray.direction = calculateRandomDirectionInHemisphere(normal, rng);
    }
    else if (isSpecular && (!isRefractive || choice < 0.5f)) {
        // Specular reflection - multiply throughput by specular color
        pathSegment.throughput *= m.specular.color;
        pathSegment.ray.direction = glm::reflect(pathSegment.ray.direction, normal);
        
        // Add roughness if specified
        if (m.specular.exponent > 0.0f && m.specular.exponent < 1000.0f) {
            glm::vec3 perfectReflection = pathSegment.ray.direction;
            glm::vec3 perturbation = calculateRandomDirectionInHemisphere(normal, rng);
            float roughness = 1.0f / (m.specular.exponent + 1.0f);
            pathSegment.ray.direction = glm::normalize(
                glm::mix(perfectReflection, perturbation, roughness * 0.1f)
            );
        }
    }
    else {
        // Treat refractive as specular for now
        pathSegment.throughput *= m.color;
        pathSegment.ray.direction = glm::reflect(pathSegment.ray.direction, normal);
    }
    
    // Update ray origin with small offset to prevent self-intersection
    pathSegment.ray.origin = intersect + 0.001f * normal;
    
    // Decrement remaining bounces
    pathSegment.remainingBounces--;
}
