#include <cstdlib>
#include <cublas_v2.h>
#include <iostream>
#include <time.h>
#include <tools/utils.h>

#include "queueDistLocks.cuh"
#include "queueShared.cuh"
#include "queuingPerProc.cuh"
#include "techniqueMegakernel.cuh"
#include "techniqueKernels.cuh"
#include "techniqueDynamicParallelism.cuh"
#include "segmentedStorage.cuh"

#include "procedureInterface.cuh"
#include "procinfoTemplate.cuh"
#include "random.cuh"

namespace Tools
{
	class CublasError : public std::runtime_error
	{
	private:
		static __host__ std::string genErrorString(cublasStatus_t error, const char* file, int line)
		{
			std::string strerror;
			switch (error)
			{
			case CUBLAS_STATUS_NOT_INITIALIZED :
				strerror = "CUBLAS_STATUS_NOT_INITIALIZED";
				break;
			case CUBLAS_STATUS_ALLOC_FAILED :
				strerror = "CUBLAS_STATUS_ALLOC_FAILED";
				break;
			case CUBLAS_STATUS_INVALID_VALUE :
				strerror = "CUBLAS_STATUS_INVALID_VALUE";
				break;
			case CUBLAS_STATUS_ARCH_MISMATCH :
				strerror = "CUBLAS_STATUS_ARCH_MISMATCH";
				break;
			case CUBLAS_STATUS_MAPPING_ERROR :
				strerror = "CUBLAS_STATUS_MAPPING_ERROR";
				break;
			case CUBLAS_STATUS_EXECUTION_FAILED :
				strerror = "CUBLAS_STATUS_EXECUTION_FAILED";
				break;
			case CUBLAS_STATUS_INTERNAL_ERROR :
				strerror = "CUBLAS_STATUS_INTERNAL_ERROR";
				break;
			case CUBLAS_STATUS_NOT_SUPPORTED :
				strerror = "CUBLAS_STATUS_NOT_SUPPORTED";
				break;
			case CUBLAS_STATUS_LICENSE_ERROR :
				strerror = "CUBLAS_STATUS_LICENSE_ERROR";
				break;
			}
		
			return std::string(file) + '(' + std::to_string(static_cast<long long>(line)) + "): error: " + strerror;
		}
	public:
		__host__ CublasError(cublasStatus_t error, const char* file, int line)
		: runtime_error(genErrorString(error, file, line))
		{
		}
	};

	inline __host__ void cublasError(cublasStatus_t error, const char* file, int line)
	{
#if defined(_DEBUG) || defined(NDEBUG)
		if (error != CUBLAS_STATUS_SUCCESS)
			throw CublasError(error, file, line);
#endif
	}
}

#define CUBLAS_CHECKED_CALL(call) Tools::cublasError(call, __FILE__, __LINE__)

struct dim2 { uint x, y; };

struct MatmulConfig
{
	float *A, *B, *C;
	size_t n;
	dim2 gridDim_;
};

__constant__ MatmulConfig config;

class MatmulTask : public ::Procedure
{
public:
	static const int NumThreads = BLOCK_SIZE * BLOCK_SIZE;
	static const bool ItemInput = false; // false results in a lvl 1	task
	static const int sharedMemory = 2 * sizeof(float) * NumThreads;	// shared memory requirements 
	
	typedef uint ExpectedData;

	template<class Q, class Context>
	static __device__ __inline__ void execute(int threadId, int numThreads, Q* queue, ExpectedData* ptaskid, volatile uint* shared) 
	{
		float*& A = config.A;
		float*& B = config.B;
		float*& C = config.C;
		size_t& n = config.n;
		dim2& gridDim_ = config.gridDim_;
	
		const uint taskid = *ptaskid;
	
		struct { uint x, y; } blockDim;
		blockDim.x = BLOCK_SIZE;
		blockDim.y = BLOCK_SIZE;
		
		struct { uint x, y; } blockIdx;
		blockIdx.x = taskid % gridDim_.x;
		blockIdx.y = taskid / gridDim_.x;
		
		struct { uint x, y; } threadIdx;
		threadIdx.x = threadId % BLOCK_SIZE;
		threadIdx.y = threadId / BLOCK_SIZE;

		// Base indexes inside A and B
		int ia = (blockDim.y * blockIdx.y) * n;
		int ib = blockDim.x * blockIdx.x;
	
		// Subindex inside a "tile"
		int tileidx = n * threadIdx.y + threadIdx.x;
	
		// Index in C
		int ic = ia + ib + tileidx;

		float sum = 0.0f;

		// Shared memory for the "tile" sub-matrix of A and B
		float* As = (float*)shared;
		float* Bs = (float*)shared + BLOCK_SIZE * BLOCK_SIZE;

		// Go through "tiles" of size blockDim.x * blockDim.y
		for (uint aoff = 0, boff = 0; aoff < n; aoff += blockDim.x, boff += blockDim.y * n)
		{
			// Load the "tile" matrices from global memory to shared memory
			As [threadIdx.y * BLOCK_SIZE + threadIdx.x] = A [ia + aoff + tileidx];
			Bs [threadIdx.y * BLOCK_SIZE + threadIdx.x] = B [ib + boff + tileidx];

			// Synchronize to make sure the matrices are loaded
			Context::sync();

			// Multiply the two matrices
			for (int k = 0; k < BLOCK_SIZE; k++)
				sum += As [threadIdx.y * BLOCK_SIZE + k] * Bs [k * BLOCK_SIZE + threadIdx.x];

			// Synchronize to make sure that the preceding
			// computation is done before loading two new
			// sub-matrices of A and B in the next iteration
			Context::sync();
		}

		// Write the block sub-matrix to global memory
		// each thread writes one element
		C [ic] = sum;

		if (threadId == numThreads - 1)
			printf("matmul task %d\n", taskid);
	}

	template<class Q>
	__device__ __inline__ static void init(Q* q, int id)
	{
		q->template enqueueInitial<MatmulTask>(id);
	}
};

enum MatmulVersion
{
	CUBLAS,
	WHIPPLETREE
};

class Matmul
{
public :
	//lets use a dist locks queue for each procedure, which can hold 12k elements
	template<class ProcInfo>
	class MyQueue : public PerProcedureQueueTyping<QueueDistLocksOpt_t, 12 * 1024, false>::Type<ProcInfo> { };

	//and lets use a Megakernel which can execute multiple workpackages concurrently (dynamic)
	//and offers a maximum of 16k shared memory
	typedef Megakernel::DynamicPointed16336<MyQueue, ProcInfo<MatmulTask> > MyTechnique;

	Matmul(float* Ah, float* Bh, float* Ch, size_t n, MatmulVersion version, float* time = NULL)
	{
		MatmulConfig hconfig;
		float*& A = hconfig.A;
		float*& B = hconfig.B;
		float*& C = hconfig.C;
		hconfig.n = n;
		hconfig.gridDim_.x = n / BLOCK_SIZE;
		hconfig.gridDim_.y = n / BLOCK_SIZE;
	
		CUDA_CHECKED_CALL(cudaMalloc(&A, sizeof(float) * n * n));
		CUDA_CHECKED_CALL(cudaMalloc(&B, sizeof(float) * n * n));
		CUDA_CHECKED_CALL(cudaMalloc(&C, sizeof(float) * n * n));

		MatmulConfig& dconfig = config;
		CUDA_CHECKED_CALL(cudaMemcpy(&dconfig, &hconfig, sizeof(MatmulConfig), cudaMemcpyHostToDevice));

		CUDA_CHECKED_CALL(cudaMemcpy(A, Ah, sizeof(float) * n * n, cudaMemcpyHostToDevice));
		CUDA_CHECKED_CALL(cudaMemcpy(B, Bh, sizeof(float) * n * n, cudaMemcpyHostToDevice));

		if (version == MatmulVersion::CUBLAS)
		{		
			cublasHandle_t handle;
			CUBLAS_CHECKED_CALL(cublasCreate(&handle));

			volatile struct timespec start;
			clock_gettime(CLOCK_REALTIME, (struct timespec*)&start);

			float fone = 1.0f, fzero = 0.0f;
			CUBLAS_CHECKED_CALL(cublasSgemm(handle,
				cublasOperation_t::CUBLAS_OP_N, cublasOperation_t::CUBLAS_OP_N,
				n, n, n, &fone, A, n, B, n, &fzero, C, n));
			
			CUDA_CHECKED_CALL(cudaDeviceSynchronize());

			volatile struct timespec finish;
			clock_gettime(CLOCK_REALTIME, (struct timespec*)&finish);

			cublasDestroy(handle);
			
			if (time)
				*time = (float)((double)0.000000001 * (finish.tv_nsec - start.tv_nsec) +
					finish.tv_sec - start.tv_sec);

		}
		if (version == MatmulVersion::WHIPPLETREE)
		{
			MyTechnique technique;
			technique.init();

			technique.insertIntoQueue<MatmulTask>(hconfig.gridDim_.x * hconfig.gridDim_.y);
			float t = technique.execute(0);
			if (time) *time = t;
		}

		CUDA_CHECKED_CALL(cudaMemcpy(Ch, C, sizeof(float) * n * n, cudaMemcpyDeviceToHost));

		CUDA_CHECKED_CALL(cudaFree(A));
		CUDA_CHECKED_CALL(cudaFree(B));
		CUDA_CHECKED_CALL(cudaFree(C));
	}
};

int main(int argc, char** argv)
{
	using namespace std;

	if (argc != 2)
	{
		cout << "Usage: " << argv[0] << " <n>" << endl;
		return 1;
	}

	int count;
	CUDA_CHECKED_CALL(cudaGetDeviceCount(&count));
	if (!count)
	{
		cerr << "No CUDA devices available" << endl;
		return -1;
	}
	cudaDeviceProp deviceProp;
	CUDA_CHECKED_CALL(cudaGetDeviceProperties(&deviceProp, 0));
	cout << "Using device: " << deviceProp.name << endl;

	size_t n = (size_t)strtoull(argv[1], NULL, 0);
	if (n % BLOCK_SIZE)
	{
		cerr << "For simplisity, we require n (" << n <<
			") to be exact multiplier of BLOCK_SIZE (" <<
			std::to_string(static_cast<long long>(BLOCK_SIZE)) << ")" << endl;
		return -1;
	}

	float *A1 = new float[n * n], *A2 = new float[n * n];
	float *B1 = new float[n * n], *B2 = new float[n * n];
	float *C1 = new float[n * n], *C2 = new float[n * n];

	// Generate random input matrices.
	double dinvrandmax = (double)1.0 / RAND_MAX;
	for (size_t i = 0, length = n * n; i < length; i++)
	{
		A1[i] = rand() * dinvrandmax; A2[i] = A1[i];
		B1[i] = rand() * dinvrandmax; B2[i] = B1[i];
	}
	memset(C1, 0, sizeof(float) * n * n);
	memset(C2, 0, sizeof(float) * n * n);

	float time;
	Matmul(A1, B1, C1, n, MatmulVersion::CUBLAS, &time);
	cout << "CUBLAS      version completed in " << time << " sec" << endl;

	Matmul(A2, B2, C2, n, MatmulVersion::CUBLAS /*WHIPPLETREE*/, &time);
	cout << "WHIPPLETREE version completed in " << time << " sec" << endl;

	// Compare results.
	int status = 0;
	for (size_t i = 0, length = n * n; i < length; i++)
	{
		if (fabsf(C1[i] - C2[i]) > 0.1f)
		{
			int Ci = i % n;
			int Cj = i / n;
			cerr << "Mismatching result @ [" << Ci << "][" << Cj << "]: " << C1[i] << " != " << C2[i] << endl;
			status = -1;
			break;
		}
	}

	delete[] A1; delete[] A2;
	delete[] B1; delete[] B2;
	delete[] C1; delete[] C2;

	return status;
}

