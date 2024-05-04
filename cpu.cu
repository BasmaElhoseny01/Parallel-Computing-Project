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

// const int DEBUG = 1;
const int K = 2;
const int MAX_ITERATIONS = 10;
const float EPSILON = 1e-4; // convergence threshold

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

__host__ float distance(float *x, float *y, int D)
{
    float dist = 0;
    for (int i = 0; i < D; i++)
    {
        dist += (x[i] - y[i]) * (x[i] - y[i]);
    }
    return sqrt(dist);
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

    // for (int i = 0; i < K; i++)
    // {
    //     for (int j = 0; j < D; j++)
    //     {
    //         printf("%f ", centroids[i * D + j]);
    //     }
    //     printf("\n");
    // }

    return centroids;
}

__host__ int *assign_data_points_to_centroids(int N, int D, int K, float *data_points, float *centroids)
{
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
    // Array to store cluster assignment for each data point [index of data point -> cluster number]
    int *cluster_assignment = (int *)malloc(N * sizeof(int));

    for (int i = 0; i < N; i++)
    {
        float min_distance = FLT_MAX; // FLT_MAX represents the maximum finite floating-point value
        int min_centroid = -1;        // -1 represents no centroid
        for (int j = 0; j < K; j++)
        { // Compute distance between data point and centroid
            float dist = 0;
            dist = distance(data_points + i * D, centroids + j * D, D); // data_points[i * D] ,centroids[j * D]

            // Update min_distance and min_centroid
            if (dist < min_distance)
            {
                min_distance = dist;
                min_centroid = j;
            }
        }
        cluster_assignment[i] = min_centroid;
    }
    printf("Cluster assignment done successfully :D\n");
    // for (int i = 0; i < N; i++)
    // {
    //     printf("%d ", cluster_assignment[i]);
    // }

    return cluster_assignment;
}

__host__ float *update_centroids(int N, int D, int K, float *data_points, float *centroids, int *cluster_assignment)
{
    /*
    Function to update the centroids

    args:
    N: number of data points
    D: number of dimensions
    K: number of clusters
    data_points: data points as a 1D array
    centroids: centroids as a 1D array
    cluster_assignment: cluster assignment for each data point

    returns: updated centroids
    */
    float *new_centroids = (float *)malloc(K * D * sizeof(float));

    // Initialize new_centroids to 0
    for (int i = 0; i < K; i++)
    {
        for (int j = 0; j < D; j++)
        {
            new_centroids[i * D + j] = 0;
        }
    }

    // Count the number of data points in each cluster
    int *cluster_count = (int *)malloc(K * sizeof(int));
    for (int i = 0; i < K; i++)
    {
        cluster_count[i] = 0;
    }

    for (int i = 0; i < N; i++)
    {
        int cluster = cluster_assignment[i];
        for (int j = 0; j < D; j++)
        {
            new_centroids[cluster * D + j] += data_points[i * D + j];
        }
        cluster_count[cluster]++;
    }

    for (int i = 0; i < K; i++)
    {
        if (cluster_count[i] == 0)
        {
            printf("Warning: Empty cluster %d\n", i);
        }
    }
    // Update the centroids
    for (int i = 0; i < K; i++)
    {
        for (int j = 0; j < D; j++)
        {
            new_centroids[i * D + j] /= cluster_count[i];
        }
    }

    printf("Centroids updated successfully :D\n");
    // Print old and new centroids
    printf("Old Centroids\n");
    for (int i = 0; i < K; i++)
    {
        for (int j = 0; j < D; j++)
        {
            printf("%f ", centroids[i * D + j]);
        }
        printf("\n");
    }
    printf("\nNew Centroids\n");
    for (int i = 0; i < K; i++)
    {
        for (int j = 0; j < D; j++)
        {
            printf("%f ", new_centroids[i * D + j]);
        }
        printf("\n");
    }

    return new_centroids;
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
    for (int i = 0; i < K; i++)
    {
        // Compute distance between old and new centroids in all dimensions
        centroids_distance += distance(centroids + i * D, new_centroids + i * D, D);
    }

    printf("Centroids distance: %f\n", centroids_distance);

    if (centroids_distance < EPSILON)
    {
        return true;
    }
    return false;
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
    if (argc != 2)
    {
        printf("Usage: %s <input_file>", argv[0]);
        exit(1);
    }

    char *input_file_path = argv[1];

    printf("Input file path: %s\n", input_file_path);

    // Read image
    int width, height, channels;
    float *image = read_image(input_file_path, &width, &height, &channels);

    int N = width * height; // no of data points
    int D = channels;       // no of dimensions [1 as start]

    // Initialize centroids
    float *centroids = intilize_centroids(N, D, K, image);

    int iteration = 0;

    while (iteration < MAX_ITERATIONS)
    {
        printf("Iteration: %d/%d\n", iteration, MAX_ITERATIONS);
        iteration = iteration + 1;

        // Assign each data point to the nearest centroid
        int *cluster_assignment = assign_data_points_to_centroids(N, D, K, image, centroids);

        // Update the centroids
        float *new_centroids = update_centroids(N, D, K, image, centroids, cluster_assignment);

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
        if (convergedCentroids >= K * 0.8)
        {
            printf("Converged\n");
            break;
        }
    }
    if (iteration == MAX_ITERATIONS)
    {
        printf("Max Iterations reached :( \n");
    }

    return 0;
}

// nvcc -o out  ./cpu.cu
// ./out ./input.png