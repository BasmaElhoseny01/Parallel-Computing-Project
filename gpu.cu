#include <stdio.h>
#include <stdlib.h>
#include <iostream>
#include <fstream>
#include <assert.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <time.h>
#include <float.h>

#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

#define THREADS_PER_BLOCK 32
#define EPSILON 0.0001
#define MAX_ITERATIONS 100
#define CONVERGENCE_PERCENTAGE 80

const int K_max = 20;
int K = -1;

__host__ float *read_image(char *path, int *width, int *height, int *channels)
{

    // Read Image
    unsigned char *image_data = stbi_load(path, width, height, channels, 0);

    if (image_data == NULL)
    {
        printf("Error loading image\n");
        exit(1);
    }
    if (*channels != 1)
    {
        printf("Error: Image should be grayscale: %d\n", *channels);
        exit(1);
    }

    // Host Memory Allocation & convert data from unsigned char to float
    float *image = (float *)malloc(sizeof(float) * (*width) * (*height) * (*channels));

    // Normlaization
    for (int i = 0; i < (*height) * (*width) * (*channels); i++)
    {
        image[i] = (float)image_data[i] / 255.0f;
    }

    if (*image == NULL)
    {
        printf("Error loading image\n");
        exit(1);
    }

    // Free the loaded image
    stbi_image_free(image_data);

    printf("Image loaded successfully\n");

    // for (int i = 0; i < (*height) * (*width) * (*channels); i++)
    // {
    //     printf("%f ", image[i]);
    // }

    return image;
}

__device__ __host__ float distance(float *x, float *y, int D)
{
    float dist = 0;
    for (int i = 0; i < D; i++)
    {
        dist += (x[i] - y[i]) * (x[i] - y[i]);
    }
    return sqrt(dist);
}

// __global__ void kMeansClusterAssignment(float *d_datapoints, int *d_clust_assn, float *d_centroids)
// {
// 	//get idx for this datapoint
// 	const int idx = blockIdx.x*blockDim.x + threadIdx.x;

// 	//bounds check
// 	if (idx >= N) return;

// 	//find the closest centroid to this datapoint
// 	float min_dist = INFINITY;
// 	int closest_centroid = 0;

// 	for(int c = 0; c<K;++c)
// 	{
// 		float dist = distance(d_datapoints[idx],d_centroids[c]);

// 		if(dist < min_dist)
// 		{
// 			min_dist = dist;
// 			closest_centroid=c;
// 		}
// 	}

// 	//assign closest cluster id for this datapoint/thread
// 	d_clust_assn[idx]=closest_centroid;
// }

/*
Function to assign each data point to the nearest centroid

args:
N: number of data points
D: number of dimensions
K: number of clusters
data_points: data points as a 1D array
centroids: centroids as a 1D array
cluster_assignment: cluster assignment for each data point

returns: None
*/
__global__ void assign_data_points_to_centroids(int N, int D, int K, float *d_data_points, float *d_centroids, int *d_cluster_assignment)
{
    // if(blockIdx.x == 0 && threadIdx.x == 0)
    // {
    //     for (int i = 0; i < K; i++)
    //     {
    //         for (int j = 0; j < D; j++)
    //         {
    //             printf("Centroids: %f ", d_centroids[i * D + j]);
    //         }
    //         printf("\n");
    //     }
    // }
    // thread index in grid level
    // each thread is responsible for 1 pixel
    const int tid = blockIdx.x * blockDim.x + threadIdx.x;

    // check for out of bounds
    // if the thread index is greater than the number of data points
    // then return
    if (tid >= N)
        return;

    float min_distance = FLT_MAX; // FLT_MAX represents the maximum finite floating-point value
    int min_centroid = -1;        // -1 represents no centroid

    for (int i = 0; i < K; i++)
    {
        // Compute the distance between the data point and the centroid
        float dist = distance(d_data_points + tid * D, d_centroids + i * D, D);

        if (dist < min_distance)
        {
            min_distance = dist;
            min_centroid = i;
        }
    }

    // Assign the data point to the nearest centroid
    d_cluster_assignment[tid] = min_centroid;
}

/**
 * @brief update clusters centroids using reduction
 *
 * @param data_points_num
 * @param dimensions_num
 * @param clusters_num
 * @param data_points
 * @param centroids
 * @param cluster_assignment
 * @return __global__
 */
__global__ void update_cluster_centroids(int data_points_num, int dimensions_num,
                                         float *d_data_points, int *d_cluster_assignment, float *d_centroids, int *d_cluster_sizes, int K)
{
    // Each block is responsible for a segment of data points
    // Each thread is responsible for a bringing data point to the shared memory
    // if(blockIdx.x == 0 && threadIdx.x == 0)
    // {
    //     for (int i = 0; i < K; i++)
    //     {
    //         for (int j = 0; j < dimensions_num; j++)
    //         {
    //             printf("Centroids: %f ", d_centroids[i * dimensions_num + j]);
    //         }
    //         printf("\n");
    //     }
    // }

    // thread in grid level
    const int grid_tid = blockIdx.x * blockDim.x + threadIdx.x;

    // check for out of bounds
    if (grid_tid >= data_points_num)
        return;

    // printf("%d ", d_cluster_assignment[grid_tid]);
    // return;

    // thread index in block level
    const int block_tid = threadIdx.x;

    // Shared memory for reduction
    __shared__ float shared_data_points[THREADS_PER_BLOCK];
    // each thread loads the data point to shared memory
    shared_data_points[block_tid] = d_data_points[grid_tid];

    __shared__ int shared_cluster_assignment[THREADS_PER_BLOCK];
    // each thread loads the cluster assignment to shared memory
    shared_cluster_assignment[block_tid] = d_cluster_assignment[grid_tid];

    __syncthreads();

    if (block_tid == 0)
    {
        float data_point_sum[K_max] = {0}; // sum of data points for each cluster
        int cluster_size[K_max] = {0};     // temporary cluster size

        // for each data point, check its cluster assignment
        // and add the data point to the corresponding cluster
        for (int i = 0; i < blockDim.x; i++)
        {
            int cluster_id = shared_cluster_assignment[i];
            data_point_sum[cluster_id] += shared_data_points[i];
            cluster_size[cluster_id] += 1;
        }

        // update the global centroids
        for (int i = 0; i < K; i++)
        {
            atomicAdd(&d_centroids[i], data_point_sum[i]);
            atomicAdd(&d_cluster_sizes[i], cluster_size[i]);
        }
    }
}
__host__ float *intilize_centroids(int N, int D, int K, float *data_points)
{
    /*
    Function to initialize centroids randomly as one of the data points

    args:
    N: number of data points
    D: number of dimensions
    K: number of clusters
    data_points: data points as a 1D array

    returns: centroids as a 1D array
    */
    srand(time(NULL)); // Seed for randomization

    float *centroids = (float *)malloc(K * D * sizeof(float));
    for (int i = 0; i < K; i++)
    {
        // Each centroid is initialized to a Random data point
        int i_random = rand() % N;
        for (int j = 0; j < D; j++)
        {
            centroids[i * D + j] = data_points[i_random * D + j];
        }
    }

    printf("Centroids initialized successfully :D\n");

    for (int i = 0; i < K; i++)
    {
        for (int j = 0; j < D; j++)
        {
            printf("%f ", centroids[i * D + j]);
        }
        printf("\n");
    }

    return centroids;
}

__host__ bool check_convergence(float *centroids, float *new_centroids, int N, int D, int K)
{
    /*
    Function to check convergence

    args:
    centroids: centroids as a 1D array
    new_centroids: updated centroids as a 1D array
    N: number of data points
    D: number of dimensions
    K: number of clusters

    returns: True if converged, False otherwise
    */
    float centroids_distance = 0;

    // Compute distance between old and new centroids in all dimensions
    centroids_distance = distance(centroids, new_centroids, D);

    // printf("Centroids distance: %f\n", centroids_distance);
    if (centroids_distance < EPSILON)
    {
        return true;
    }
    return false;
}

__host__ int **generate_cluster_color()
{
    int **cluster_color = (int **)malloc(K * sizeof(int *));

    for (int i = 0; i < K; i++)
    {
        cluster_color[i] = (int *)malloc(3 * sizeof(int));
        for (int j = 0; j < 3; j++)
        {
            cluster_color[i][j] = rand() % 256;
        }
        // if reepating colors [Reassign color]
        for (int j = 0; j < i; j++)
        {
            if (cluster_color[i][0] == cluster_color[j][0] && cluster_color[i][1] == cluster_color[j][1] && cluster_color[i][2] == cluster_color[j][2])
            {
                i--;
                break;
            }
        }
    }
    return cluster_color;
}

__host__ unsigned char *clutser_image(float *image, int width, int height, int channels, int *cluster_assignment)
{
    // Get assigned cluster for each pixel
    int N = width * height;
    int D = channels;

    // Cluster the image
    unsigned char *clustered_image = (unsigned char *)malloc(sizeof(unsigned char) * height * width * 3);
    // float *clustered_image = (float *)malloc(sizeof(float) * height * width * 3);

    // Generate Cluster Colors
    int **cluster_color = generate_cluster_color();
    printf("Cluster Colors Generated\n");
    for (int i = 0; i < K; i++)
    {
        for (int j = 0; j < 3; j++)
        {
            printf("%d ", cluster_color[i][j]);
        }
        printf("\n");
    }

    // Assign color to each pixel
    for (int i = 0; i < N; i++)
    {
        for (int j = 0; j < 3; j++)
        {
            clustered_image[i * 3 + j] = cluster_color[cluster_assignment[i]][j];
        }
    }

    printf("Image clustered successfully :D\n");

    // Write Image
    return clustered_image;
}

/*
Kmeans:
1. Initialize centroids (Random or Kmeans++)
2. Assign each data point to the nearest centroid
3. Update the centroids
4. Repeat 2 and 3 until convergence
*/
int main(int argc, char *argv[])
{

    printf("Hello World\n");

    // Input Arguments
    if (argc < 2)
    {
        printf("Usage: %s <input_file>", argv[0]);
        exit(1);
    }

    char *input_file_path = argv[1];
    K = atoi(argv[2]);

    printf("Input file path: %s\n", input_file_path);

    // Read image
    int width, height, channels;
    float *image = read_image(input_file_path, &width, &height, &channels);

    // Number of blocks
    int N = width * height; // no of data points
    int D = channels;       // no of dimensions [1 as start]

    // Initialize centroids
    float *centroids = intilize_centroids(N, D, K, image);
    int *cluster_assignment = (int *)malloc(N * sizeof(int));
    int *cluster_sizes = (int *)malloc(K * sizeof(int)); // Array to store the size of each cluster

    // Device Memory Allocation
    float *d_image = 0;
    float *d_centroids = 0;
    int *d_cluster_assignment = 0;
    int *d_cluster_sizes = 0;

    cudaMalloc(&d_image, N * D * sizeof(float));
    cudaMalloc(&d_centroids, K * D * sizeof(float));
    cudaMalloc(&d_cluster_assignment, N * sizeof(int));
    cudaMalloc(&d_cluster_sizes, K * sizeof(int)); // Array to store the size of each cluster

    // Copy data from host to devic [image]
    cudaMemcpy(d_image, image, N * D * sizeof(float), cudaMemcpyHostToDevice);

    int num_blocks = (N + THREADS_PER_BLOCK - 1) / THREADS_PER_BLOCK; // ceil(N/THREADS_PER_BLOCK)

    int iteration = 0;
    while (iteration < MAX_ITERATIONS)
    {
        // print the current
        iteration++;
        printf("Iteration: %d/%d\n", iteration, MAX_ITERATIONS);

        // Copy data from host to device [centroids]
        cudaMemcpy(d_centroids, centroids, K * D * sizeof(float), cudaMemcpyHostToDevice);

        // call the kernel [assign_data_points_to_centroids]
        assign_data_points_to_centroids<<<num_blocks, THREADS_PER_BLOCK>>>(N, D, K, d_image, d_centroids, d_cluster_assignment);

        cudaDeviceSynchronize();
        cudaError_t error = cudaGetLastError();
        if (error != cudaSuccess)
        {
            // in red
            printf("\033[1;31m");
            printf("CUDA error [After assign_data_points_to_centroids()]: %s\n", cudaGetErrorString(error));
            // reset color
            printf("\033[0m");
        }

        printf("Cluster assignment done successfully :D\n");

        // Reset the cluster sizes
        cudaMemset(d_cluster_sizes, 0, K * sizeof(int));

        update_cluster_centroids<<<num_blocks, THREADS_PER_BLOCK>>>(N, D, d_image, d_cluster_assignment, d_centroids, d_cluster_sizes, K);
        cudaDeviceSynchronize();
        error = cudaGetLastError();
        if (error != cudaSuccess)
        {
            // in red
            printf("\033[1;31m");
            printf("CUDA error [After update_cluster_centroids()]: %s\n", cudaGetErrorString(error));
            // reset color
            printf("\033[0m");
        }

        // Copy data from device to host
        // To Hold new Centroids
        float *new_centroids = (float *)malloc(K * D * sizeof(float));
        cudaMemcpy(new_centroids, d_centroids, K * D * sizeof(float), cudaMemcpyDeviceToHost);
        cudaMemcpy(cluster_sizes, d_cluster_sizes, K * sizeof(int), cudaMemcpyDeviceToHost);

        for (int i = 0; i < K; i++)
        {
            if (cluster_sizes[i] == 0)
            {
                printf("Warning: Empty cluster %d\n", i);
            }
        }
        // Update the centroids
        for (int i = 0; i < K; i++)
        {
            for (int j = 0; j < D; j++)
            {
                new_centroids[i * D + j] /= cluster_sizes[i];
            }
        }
        // printf("Centroids updated successfully :D\n");
        // printf("Clusters Sizes: %d\n", sum);
        // printf("Points Sum: %d\n", sum2);
        // printf("*************************\n");
        // // Print old and new centroids
        // printf("Old Centroids\n");
        // for (int i = 0; i < K; i++)
        // {
        //     for (int j = 0; j < D; j++)
        //     {
        //         printf("%f ", centroids[i * D + j]);
        //     }
        //     printf("\n");
        // }
        // printf("\nNew Centroids\n");
        // for (int i = 0; i < K; i++)
        // {
        //     for (int j = 0; j < D; j++)
        //     {
        //         printf("%f ", new_centroids[i * D + j]);
        //     }
        //     printf("\n");
        // }
        // printf("*************************\n");

        // check convergence
        int convergedCentroids = 0;
        for (int i = 0; i < K; i++)
        {
            if (check_convergence(centroids + i * D, new_centroids + i * D, N, D, K))
            {
                convergedCentroids++;
            }
        }
        printf("Converged Centroids: %d\n", convergedCentroids);
        // if 80% of the centroids have converged
        if (convergedCentroids >= K * CONVERGENCE_PERCENTAGE / 100.0)
        {
            printf("Converged\n");
            break;
        }

        // Update centroids
        centroids = new_centroids;
    }
    if (iteration == MAX_ITERATIONS)
    {
        printf("Max Iterations reached :( \n");
    }

    // // Copy Assigments
    cudaMemcpy(cluster_assignment, d_cluster_assignment, N * sizeof(int), cudaMemcpyDeviceToHost);
    // Cluster Assignments
    // printf("*************************\n");
    // for (int i = 0; i < N; i++)
    // {
    // printf("%d ", cluster_assignment[i]);
    // }
    // Cluster the image
    unsigned char *clutsered_image = clutser_image(image, width, height, channels, cluster_assignment);

    // Save the clustered image
    std::string input_path(input_file_path);
    std::string output_path = input_path.substr(0, input_path.find_last_of('.')) + "_output_gpu.png";
    stbi_write_png(output_path.c_str(), width, height, 3, clutsered_image, width * 3);
    printf("Image saved successfully at: %s\n", output_path.c_str());

    return 0;
}

// nvcc -o out_gpu_1  ./gpu.cu
// ./out_gpu_1 .\tests\image_3_grey.png 2