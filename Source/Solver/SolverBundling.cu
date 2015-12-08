#include <iostream>

#include "SolverBundlingParameters.h"
#include "SolverBundlingState.h"
#include "SolverBundlingUtil.h"
#include "SolverBundlingEquations.h"
#include "../../SiftGPU/CUDATimer.h"

#include <conio.h>

/////////////////////////////////////////////////////////////////////////
// Dense Depth Term
/////////////////////////////////////////////////////////////////////////
#define THREADS_PER_BLOCK_DENSE_DEPTH_X 32
#define THREADS_PER_BLOCK_DENSE_DEPTH_Y 4 
#define THREADS_PER_BLOCK_DENSE_DEPTH_FLIP 64

__device__ void computeJacobianBlockRow_i(matNxM<1, 6>& jacBlockRow, const float3& angles, const float3& translation,
	const float4x4& transform_j, const float4& camPosSrc, const float4& normalTgt)
{
	float4 world = transform_j * camPosSrc;
	//alpha
	float4x4 dx = evalRtInverse_dAlpha(angles, translation);
	jacBlockRow(0) = -dot(dx * world, normalTgt);
	//beta
	dx = evalRtInverse_dBeta(angles, translation);
	jacBlockRow(1) = -dot(dx * world, normalTgt);
	//gamma
	dx = evalRtInverse_dGamma(angles, translation);
	jacBlockRow(2) = -dot(dx * world, normalTgt);
	//x
	dx = evalRtInverse_dX(angles, translation);
	jacBlockRow(3) = -dot(dx * world, normalTgt);
	//y
	dx = evalRtInverse_dY(angles, translation);
	jacBlockRow(4) = -dot(dx * world, normalTgt);
	//z
	dx = evalRtInverse_dZ(angles, translation);
	jacBlockRow(5) = -dot(dx * world, normalTgt);
}
__device__ void computeJacobianBlockRow_j(matNxM<1, 6>& jacBlockRow, const float3& angles, const float3& translation,
	const float4x4& invTransform_i, const float4& camPosSrc, const float4& normalTgt)
{
	float4x4 dx; dx.setIdentity();
	//alpha
	dx.setFloat3x3(evalR_dAlpha(angles));
	jacBlockRow(0) = -dot(invTransform_i * dx * camPosSrc, normalTgt);
	//beta
	dx.setFloat3x3(evalR_dBeta(angles));
	jacBlockRow(1) = -dot(invTransform_i * dx * camPosSrc, normalTgt);
	//gamma
	dx.setFloat3x3(evalR_dGamma(angles));
	jacBlockRow(2) = -dot(invTransform_i * dx * camPosSrc, normalTgt);
	//x
	float4 dt = make_float4(1.0f, 0.0f, 0.0f, 0.0f);
	jacBlockRow(3) = -dot(invTransform_i * dt, normalTgt);
	//y
	dt = make_float4(0.0f, 1.0f, 0.0f, 0.0f);
	jacBlockRow(4) = -dot(invTransform_i * dt, normalTgt);
	//z
	dt = make_float4(0.0f, 0.0f, 1.0f, 0.0f);
	jacBlockRow(5) = -dot(invTransform_i * dt, normalTgt);
}
__device__ void addToLocalSystem(float* d_JtJ, float* d_Jtr, unsigned int dim, const matNxM<1, 6>& jacobianBlockRow_i, const matNxM<1, 6>& jacobianBlockRow_j,
	unsigned int vi, unsigned int vj, float residual, float weight)
{
	for (unsigned int i = 0; i < 6; i++) {
		for (unsigned int j = i; j < 6; j++) {
			if (vi > 0) {
				float dii = jacobianBlockRow_i(i) * jacobianBlockRow_i(j) * weight;
				atomicAdd(&d_JtJ[(vi * 6 + j)*dim + (vi * 6 + i)], dii);
				printf("ERROR vi %d\n", vi);
			}
			if (vj > 0) {
				float djj = jacobianBlockRow_j(i) * jacobianBlockRow_j(j) * weight;
				atomicAdd(&d_JtJ[(vj * 6 + j)*dim + (vj * 6 + i)], djj);
			}
			if (vi > 0 && vj > 0) {
				printf("ERROR vi %d\n", vi);
				float dij = jacobianBlockRow_i(i) * jacobianBlockRow_j(j) * weight;
				atomicAdd(&d_JtJ[(vj * 6 + j)*dim + (vi * 6 + i)], dij);
				atomicAdd(&d_JtJ[(vi * 6 + i)*dim + (vj * 6 + j)], dij);
			}
		}
		if (vi > 0) atomicAdd(&d_Jtr[vi * 6 + i], jacobianBlockRow_i(i) * residual * weight);
		if (vj > 0) atomicAdd(&d_Jtr[vj * 6 + i], jacobianBlockRow_j(i) * residual * weight);
	}
}
__device__ bool findDenseDepthCorr(unsigned int idx, unsigned int imageWidth, unsigned int imageHeight,
	float distThresh, float normalThresh, /*float colorThresh,*/ const float4x4& transform, const float4x4& intrinsics,
	const float4* tgtCamPos, const float4* tgtNormals, const float4* srcCamPos, const float4* srcNormals, float depthMin, float depthMax,
	float4& camPosSrcToTgt, float4& camPosTgt, float4& normalTgt)
{
	//!!!DEBUGGING
	const unsigned int x = idx % imageWidth; const unsigned int y = idx / imageWidth;
	bool debugPrint = false;//(x == 1 && y == 19);
	if (debugPrint) {
		printf("transform:\n");
		transform.print();
	}
	//!!!DEBUGGING

	const float4& cposj = srcCamPos[idx];
	if (debugPrint) printf("cam pos j = %f %f %f %f\n", cposj.x, cposj.y, cposj.z, cposj.w);
	if (cposj.z > depthMin && cposj.z < depthMax) {
		float4 nrmj = srcNormals[idx];
		if (debugPrint) printf("normal j = %f %f %f %f\n", nrmj.x, nrmj.y, nrmj.z, nrmj.w);
		if (nrmj.x != MINF) {
			nrmj = transform * nrmj;
			camPosSrcToTgt = transform * cposj;
			float3 proj = intrinsics * make_float3(camPosSrcToTgt.x, camPosSrcToTgt.y, camPosSrcToTgt.z);
			int2 screenPos = make_int2((int)roundf(proj.x / proj.z), (int)roundf(proj.y / proj.z));
			if (debugPrint) {
				printf("cam pos j2i = %f %f %f %f\n", camPosSrcToTgt.x, camPosSrcToTgt.y, camPosSrcToTgt.z, camPosSrcToTgt.w);
				printf("screen pos = %d %d\n", screenPos.x, screenPos.y);
			}
			if (screenPos.x >= 0 && screenPos.y >= 0 && screenPos.x < (int)imageWidth && screenPos.y < (int)imageHeight) {
				camPosTgt = tgtCamPos[screenPos.y * imageWidth + screenPos.x];
				if (debugPrint) printf("cam pos i = %f %f %f %f\n", camPosTgt.x, camPosTgt.y, camPosTgt.z, camPosTgt.w);
				if (camPosTgt.z > depthMin && camPosTgt.z < depthMax) {
					normalTgt = tgtNormals[screenPos.y * imageWidth + screenPos.x];
					if (debugPrint) printf("normal i = %f %f %f %f\n", normalTgt.x, normalTgt.y, normalTgt.z, normalTgt.w);
					if (normalTgt.x != MINF) {
						float dist = length(camPosSrcToTgt - camPosTgt);
						float dNormal = dot(nrmj, normalTgt);
						if (debugPrint) printf("(dist,dnormal) = %f %f\n", dist, dNormal);
						if (dNormal >= normalThresh && dist <= distThresh) {
							return true;
						}
					}
				}
			} // valid projection
		} // valid src normal
	} // valid src camera position
	return false;
}
__global__ void BuildDenseDepthSystem_Kernel(SolverInput input, SolverState state, SolverParameters parameters)
{
	// image indices
	// all pairwise
	const unsigned int i = blockIdx.x; const unsigned int j = blockIdx.y; // project from j to i
	if (blockIdx.x == 0 && blockIdx.y == 0 && blockIdx.z == 0 && threadIdx.x == 0 && threadIdx.y == 0) {
		printf("[ grid dim %d %d %d ] [ block dim %d %d %d ]\n", gridDim.x, gridDim.y, gridDim.z, blockDim.x, blockDim.y, blockDim.z);
	}
	if (i >= j) return;
	//// frame-to-frame
	//const unsigned int i = blockIdx.x; const unsigned int j = i + 1; // project from j to i

	const unsigned int idx = threadIdx.y * THREADS_PER_BLOCK_DENSE_DEPTH_X + threadIdx.x;
	const unsigned int gidx = idx * gridDim.z + blockIdx.z; //TODO CHECK INDEXING


	if (gidx < (input.denseDepthWidth * input.denseDepthHeight)) {
		//if (i == 0 && j == 1 && blockIdx.z == 0 && threadIdx.x < 10 && threadIdx.y < 10) {
		//	const unsigned int x = gidx % input.denseDepthWidth;
		//	const unsigned int y = gidx / input.denseDepthWidth;
		//	printf("(%d,%d,%d)(%d,%d,%d) -> images (%d,%d) id (%d,%d) loc (%d,%d)\n",
		//		blockIdx.x, blockIdx.y, blockIdx.z, threadIdx.x, threadIdx.y, threadIdx.z, i, j, idx, gidx, x, y);
		//}

		float4x4 transform_i = evalRtMat(state.d_xRot[i], state.d_xTrans[i]);
		float4x4 transform_j = evalRtMat(state.d_xRot[j], state.d_xTrans[j]);
		float4x4 invTransform_i = transform_i.getInverse(); //TODO unncessary invert for pairwise?

		float4x4 transform = invTransform_i * transform_j;

		// find correspondence
		float4 camPosSrcToTgt, camPosTgt, normalTgt;
		if (findDenseDepthCorr(gidx, input.denseDepthWidth, input.denseDepthHeight,
			parameters.denseDepthDistThresh, parameters.denseDepthNormalThresh, transform, input.depthIntrinsics,
			input.d_depthFrames[i].d_cameraposDownsampled, input.d_depthFrames[i].d_normalsDownsampled,
			input.d_depthFrames[j].d_cameraposDownsampled, input.d_depthFrames[j].d_normalsDownsampled,
			parameters.denseDepthMin, parameters.denseDepthMax, camPosSrcToTgt, camPosTgt, normalTgt)) { //i tgt, j src
			// residual
			float4 diff = camPosTgt - camPosSrcToTgt;
			float res = dot(diff, normalTgt);

			// jacobian
			const float4& camPosSrc = input.d_depthFrames[i].d_cameraposDownsampled[gidx];
			matNxM<1, 6> jacobianBlockRow_i, jacobianBlockRow_j;
			if (i > 0) computeJacobianBlockRow_i(jacobianBlockRow_i, state.d_xRot[i], state.d_xTrans[i], transform_j, camPosSrc, normalTgt);
			if (j > 0) computeJacobianBlockRow_j(jacobianBlockRow_j, state.d_xRot[j], state.d_xTrans[j], invTransform_i, camPosSrc, normalTgt);
			float weight = max(0.0f, 0.5f*((1.0f - length(diff) / parameters.denseDepthDistThresh) + (1.0f - camPosTgt.z / parameters.denseDepthMax)));

			//!!!debugging
			//const unsigned int x = gidx % input.denseDepthWidth; const unsigned int y = gidx / input.denseDepthWidth;
			//if (x == 2 && y == 19) {
			//	printf("-----------\n");
			//	printf("(%d, %d)\n", x, y);
			//	printf("transform i:\n"); transform_i.print();
			//	printf("transform j:\n"); transform_j.print();
			//	printf("transform:\n"); transform.print();
			//	printf("cam pos src: %f %f %f\n", camPosSrc.x, camPosSrc.y, camPosSrc.z);
			//	printf("cam pos src to tgt: %f %f %f\n", camPosSrcToTgt.x, camPosSrcToTgt.y, camPosSrcToTgt.z);
			//	printf("cam pos tgt: %f %f %f\n", camPosTgt.x, camPosTgt.y, camPosTgt.z);
			//	printf("normal tgt: %f %f %f\n", normalTgt.x, normalTgt.y, normalTgt.z);
			//	printf("diff = %f %f %f %f\n", diff.x, diff.y, diff.z, diff.w);
			//	printf("res = %f\n", res);
			//	printf("weight = %f\n", parameters.weightDenseDepth * weight);
			//	printf("jac %f %f %f %f %f %f\n", jacobianBlockRow_j(0), jacobianBlockRow_j(1), jacobianBlockRow_j(2),
			//		jacobianBlockRow_j(3), jacobianBlockRow_j(4), jacobianBlockRow_j(5));
			//}
			//!!!debugging

			addToLocalSystem(state.d_depthJtJ, state.d_depthJtr, input.numberOfImages * 6,
				jacobianBlockRow_i, jacobianBlockRow_j, i, j, res, parameters.weightDenseDepth * weight);
		} // found correspondence
	} // valid image pixel
}

void BuildDenseDepthSystem(SolverInput& input, SolverState& state, SolverParameters& parameters, CUDATimer* timer)
{
	const unsigned int N = input.numberOfImages;

	const int threadsPerBlock = THREADS_PER_BLOCK_DENSE_DEPTH_X * THREADS_PER_BLOCK_DENSE_DEPTH_Y;
	const int reductionGlobal = (input.denseDepthWidth*input.denseDepthHeight + threadsPerBlock - 1) / threadsPerBlock;
	const int sizeJtr = 6 * N;
	const int sizeJtJ = sizeJtr * sizeJtr;

	dim3 grid(N, N, reductionGlobal); // for all pairwise
	//dim3 grid(N - 1, 1, reductionGlobal); // for frame-to-frame
	dim3 block(THREADS_PER_BLOCK_DENSE_DEPTH_X, THREADS_PER_BLOCK_DENSE_DEPTH_Y);

	if (timer) timer->startEvent("BuildDenseDepthSystem");

	//debugging
	//CUDATimer t; t.startEvent("BuildDenseDepthSystem");

	MLIB_CUDA_SAFE_CALL(cudaMemset(state.d_depthJtJ, 0, sizeof(float) * sizeJtJ)); //TODO check if necessary
	MLIB_CUDA_SAFE_CALL(cudaMemset(state.d_depthJtr, 0, sizeof(float) * sizeJtr));
#ifdef _DEBUG
	cutilSafeCall(cudaDeviceSynchronize());
	cutilCheckMsg(__FUNCTION__);
#endif		

	if (parameters.weightDenseDepth > 0.0f) {
		BuildDenseDepthSystem_Kernel << <grid, block >> >(input, state, parameters);
#ifdef _DEBUG
		cutilSafeCall(cudaDeviceSynchronize());
		cutilCheckMsg(__FUNCTION__);
#endif	

		//!!!debugging 
		float* h_JtJ = new float[sizeJtJ];
		float* h_Jtr = new float[sizeJtr];
		MLIB_CUDA_SAFE_CALL(cudaMemcpy(h_JtJ, state.d_depthJtJ, sizeof(float) * sizeJtJ, cudaMemcpyDeviceToHost));
		MLIB_CUDA_SAFE_CALL(cudaMemcpy(h_Jtr, state.d_depthJtr, sizeof(float) * sizeJtr, cudaMemcpyDeviceToHost));
		printf("JtJ:\n");
		for (unsigned int i = 0; i < 6 * N; i++) {
			for (unsigned int j = 0; j < 6 * N; j++)
				printf(" %f", h_JtJ[j * 6 * N + i]);
			printf("\n");
		}
		printf("Jtr:\n");
		for (unsigned int i = 0; i < 6 * N; i++) {
			printf(" %f", h_Jtr[i]);
		}
		printf("\n");
		if (h_JtJ) delete[] h_JtJ;
		if (h_Jtr) delete[] h_Jtr;

		//debugging
		//t.evaluate();
	}
	if (timer) timer->endEvent();
}

/////////////////////////////////////////////////////////////////////////
// Eval Max Residual
/////////////////////////////////////////////////////////////////////////

__global__ void EvalMaxResidualDevice(SolverInput input, SolverState state, SolverParameters parameters)
{
	__shared__ int maxResIndex[THREADS_PER_BLOCK];
	__shared__ float maxRes[THREADS_PER_BLOCK];

	const unsigned int N = input.numberOfCorrespondences * 3; // Number of block variables
	const unsigned int x = blockIdx.x * blockDim.x + threadIdx.x;

	maxResIndex[threadIdx.x] = 0;
	maxRes[threadIdx.x] = 0.0f;

	if (x < N) {
		const unsigned int corrIdx = x / 3;
		const unsigned int componentIdx = x - corrIdx * 3;
		float residual = evalResidualDeviceFloat3(corrIdx, componentIdx, input, state, parameters);

		maxRes[threadIdx.x] = residual;
		maxResIndex[threadIdx.x] = x;

		__syncthreads();

		for (int stride = THREADS_PER_BLOCK / 2; stride > 0; stride /= 2) {

			if (threadIdx.x < stride) {
				int first = threadIdx.x;
				int second = threadIdx.x + stride;
				if (maxRes[first] < maxRes[second]) {
					maxRes[first] = maxRes[second];
					maxResIndex[first] = maxResIndex[second];
				}
			}

			__syncthreads();
		}

		if (threadIdx.x == 0) {
			//printf("d_maxResidual[%d] = %f (index %d)\n", blockIdx.x, maxRes[0], maxResIndex[0]);
			state.d_maxResidual[blockIdx.x] = maxRes[0];
			state.d_maxResidualIndex[blockIdx.x] = maxResIndex[0];
		}
	}
}

extern "C" void evalMaxResidual(SolverInput& input, SolverState& state, SolverParameters& parameters, CUDATimer* timer)
{
	if (timer) timer->startEvent(__FUNCTION__);

	const unsigned int N = input.numberOfCorrespondences * 3; // Number of correspondences (*3 per xyz)
	EvalMaxResidualDevice << <(N + THREADS_PER_BLOCK - 1) / THREADS_PER_BLOCK, THREADS_PER_BLOCK >> >(input, state, parameters);

#ifdef _DEBUG
	cutilSafeCall(cudaDeviceSynchronize());
	cutilCheckMsg(__FUNCTION__);
#endif
	if (timer) timer->endEvent();
}

/////////////////////////////////////////////////////////////////////////
// Eval Cost
/////////////////////////////////////////////////////////////////////////

__global__ void ResetResidualDevice(SolverInput input, SolverState state, SolverParameters parameters)
{
	const unsigned int x = blockIdx.x * blockDim.x + threadIdx.x;
	if (x == 0) state.d_sumResidual[0] = 0.0f;
}

__global__ void EvalResidualDevice(SolverInput input, SolverState state, SolverParameters parameters)
{
	const unsigned int N = input.numberOfCorrespondences; // Number of block variables
	const unsigned int x = blockIdx.x * blockDim.x + threadIdx.x;

	float residual = 0.0f;
	if (x < N) {
		residual = evalFDevice(x, input, state, parameters);
		//float out = warpReduce(residual);
		//unsigned int laneid;
		////This command gets the lane ID within the current warp
		//asm("mov.u32 %0, %%laneid;" : "=r"(laneid));
		//if (laneid == 0) {
		//	atomicAdd(&state.d_sumResidual[0], out);
		//}
		atomicAdd(&state.d_sumResidual[0], residual);
	}
}

float EvalResidual(SolverInput& input, SolverState& state, SolverParameters& parameters, CUDATimer* timer)
{
	if (timer) timer->startEvent(__FUNCTION__);

	float residual = 0.0f;

	const unsigned int N = input.numberOfCorrespondences; // Number of block variables
	ResetResidualDevice << < 1, 1, 1 >> >(input, state, parameters);
	EvalResidualDevice << <(N + THREADS_PER_BLOCK - 1) / THREADS_PER_BLOCK, THREADS_PER_BLOCK >> >(input, state, parameters);

	residual = state.getSumResidual();

#ifdef _DEBUG
	cutilSafeCall(cudaDeviceSynchronize());
	cutilCheckMsg(__FUNCTION__);
#endif
	if (timer) timer->endEvent();

	return residual;
}

/////////////////////////////////////////////////////////////////////////
// Eval Linear Residual
/////////////////////////////////////////////////////////////////////////

//__global__ void SumLinearResDevice(SolverInput input, SolverState state, SolverParameters parameters)
//{
//	const unsigned int N = input.numberOfImages; // Number of block variables
//	const unsigned int x = blockIdx.x * blockDim.x + threadIdx.x;
//
//	float residual = 0.0f;
//	if (x > 0 && x < N) {
//		residual = dot(state.d_rRot[x], state.d_rRot[x]) + dot(state.d_rTrans[x], state.d_rTrans[x]);
//		atomicAdd(state.d_sumLinResidual, residual);
//	}
//}
//float EvalLinearRes(SolverInput& input, SolverState& state, SolverParameters& parameters)
//{
//	float residual = 0.0f;
//
//	const unsigned int N = input.numberOfImages;	// Number of block variables
//
//	// Do PCG step
//	const int blocksPerGrid = (N + THREADS_PER_BLOCK - 1) / THREADS_PER_BLOCK;
//
//	float init = 0.0f;
//	cutilSafeCall(cudaMemcpy(state.d_sumLinResidual, &init, sizeof(float), cudaMemcpyHostToDevice));
//
//	SumLinearResDevice << <blocksPerGrid, THREADS_PER_BLOCK >> >(input, state, parameters);
//#ifdef _DEBUG
//	cutilSafeCall(cudaDeviceSynchronize());
//	cutilCheckMsg(__FUNCTION__);
//#endif
//
//	cutilSafeCall(cudaMemcpy(&residual, state.d_sumLinResidual, sizeof(float), cudaMemcpyDeviceToHost));
//	return residual;
//}

/////////////////////////////////////////////////////////////////////////
// Count High Residuals
/////////////////////////////////////////////////////////////////////////

__global__ void CountHighResidualsDevice(SolverInput input, SolverState state, SolverParameters parameters)
{
	const unsigned int N = input.numberOfCorrespondences * 3; // Number of block variables
	const unsigned int x = blockIdx.x * blockDim.x + threadIdx.x;

	if (x < N) {
		const unsigned int corrIdx = x / 3;
		const unsigned int componentIdx = x - corrIdx * 3;
		float residual = evalResidualDeviceFloat3(corrIdx, componentIdx, input, state, parameters);

		if (residual > parameters.verifyOptDistThresh)
			atomicAdd(state.d_countHighResidual, 1);
	}
}

extern "C" int countHighResiduals(SolverInput& input, SolverState& state, SolverParameters& parameters, CUDATimer* timer)
{
	if (timer) timer->startEvent(__FUNCTION__);

	const unsigned int N = input.numberOfCorrespondences * 3; // Number of correspondences (*3 per xyz)
	cutilSafeCall(cudaMemset(state.d_countHighResidual, 0, sizeof(int)));
	CountHighResidualsDevice << <(N + THREADS_PER_BLOCK - 1) / THREADS_PER_BLOCK, THREADS_PER_BLOCK >> >(input, state, parameters);

	int count;
	cutilSafeCall(cudaMemcpy(&count, state.d_countHighResidual, sizeof(int), cudaMemcpyDeviceToHost));
#ifdef _DEBUG
	cutilSafeCall(cudaDeviceSynchronize());
	cutilCheckMsg(__FUNCTION__);
#endif

	if (timer) timer->endEvent();
	return count;
}




// For the naming scheme of the variables see:
// http://en.wikipedia.org/wiki/Conjugate_gradient_method
// This code is an implementation of their PCG pseudo code

__global__ void PCGInit_Kernel1(SolverInput input, SolverState state, SolverParameters parameters)
{
	const unsigned int N = input.numberOfImages;
	const int x = blockIdx.x * blockDim.x + threadIdx.x;

	float d = 0.0f;
	if (x > 0 && x < N)
	{
		float3 resRot, resTrans;
		evalMinusJTFDevice(x, input, state, parameters, resRot, resTrans);  // residuum = J^T x -F - A x delta_0  => J^T x -F, since A x x_0 == 0 

		state.d_rRot[x] = resRot;											// store for next iteration
		state.d_rTrans[x] = resTrans;										// store for next iteration

		const float3 pRot = state.d_precondionerRot[x] * resRot;			// apply preconditioner M^-1
		state.d_pRot[x] = pRot;

		const float3 pTrans = state.d_precondionerTrans[x] * resTrans;		// apply preconditioner M^-1
		state.d_pTrans[x] = pTrans;

		d = dot(resRot, pRot) + dot(resTrans, pTrans);						// x-th term of nomimator for computing alpha and denominator for computing beta

		state.d_Ap_XRot[x] = make_float3(0.0f, 0.0f, 0.0f);
		state.d_Ap_XTrans[x] = make_float3(0.0f, 0.0f, 0.0f);
	}

	d = warpReduce(d);
	if (threadIdx.x % WARP_SIZE == 0)
	{
		atomicAdd(state.d_scanAlpha, d);
	}
}

__global__ void PCGInit_Kernel2(unsigned int N, SolverState state)
{
	const unsigned int x = blockIdx.x * blockDim.x + threadIdx.x;

	if (x > 0 && x < N) state.d_rDotzOld[x] = state.d_scanAlpha[0];				// store result for next kernel call
}

void Initialization(SolverInput& input, SolverState& state, SolverParameters& parameters, CUDATimer* timer)
{
	const unsigned int N = input.numberOfImages;

	const int blocksPerGrid = (N + THREADS_PER_BLOCK - 1) / THREADS_PER_BLOCK;

	if (blocksPerGrid > THREADS_PER_BLOCK)
	{
		std::cout << "Too many variables for this block size. Maximum number of variables for two kernel scan: " << THREADS_PER_BLOCK*THREADS_PER_BLOCK << std::endl;
		while (1);
	}

	if (timer) timer->startEvent("Init1");

	cutilSafeCall(cudaMemset(state.d_scanAlpha, 0, sizeof(float)));
#ifdef _DEBUG
	cutilSafeCall(cudaDeviceSynchronize());
	cutilCheckMsg(__FUNCTION__);
#endif		

	PCGInit_Kernel1 << <blocksPerGrid, THREADS_PER_BLOCK >> >(input, state, parameters);
#ifdef _DEBUG
	cutilSafeCall(cudaDeviceSynchronize());
	cutilCheckMsg(__FUNCTION__);
#endif		
	if (timer) timer->endEvent();

	if (timer) timer->startEvent("Init2");
	PCGInit_Kernel2 << <blocksPerGrid, THREADS_PER_BLOCK >> >(N, state);
#ifdef _DEBUG
	cutilSafeCall(cudaDeviceSynchronize());
	cutilCheckMsg(__FUNCTION__);
#endif

	if (timer) timer->endEvent();
}

/////////////////////////////////////////////////////////////////////////
// PCG Iteration Parts
/////////////////////////////////////////////////////////////////////////

__global__ void PCGStep_Kernel0(SolverInput input, SolverState state, SolverParameters parameters)
{
	const unsigned int N = input.numberOfCorrespondences;					// Number of block variables
	const unsigned int x = blockIdx.x * blockDim.x + threadIdx.x;

	if (x < N)
	{
		const float3 tmp = applyJDevice(x, input, state, parameters);		// A x p_k  => J^T x J x p_k 
		state.d_Jp[x] = tmp;												// store for next kernel call
	}
}

//__global__ void PCGStep_Kernel1(SolverInput input, SolverState state, SolverParameters parameters)
//
//	const unsigned int N = input.numberOfImages;							// Number of block variables
//	const unsigned int xHat = blockIdx.x * blockDim.x + threadIdx.x;
//
//	const unsigned int x = xHat / 32;
//	const unsigned int lane = threadIdx.x % WARP_SIZE;
//
//	float d = 0.0f;
//	if (x > 0 && x < N)
//	{
//		float3 rot, trans;
//		applyJTDevice(x, input, state, parameters, rot, trans, lane);			// A x p_k  => J^T x J x p_k 
//
//		if (lane == 0)
//		{
//			state.d_Ap_XRot[x] = rot;											// store for next kernel call
//			state.d_Ap_XTrans[x] = trans;										// store for next kernel call
//
//			d = dot(state.d_pRot[x], rot) + dot(state.d_pTrans[x], trans);		// x-th term of denominator of alpha
//		}
//	}
//	//d = warpReduce(d);
//	if (threadIdx.x % WARP_SIZE == 0)
//	{
//		atomicAdd(state.d_scanAlpha, d);
//	}
//

__global__ void PCGStep_Kernel1a(SolverInput input, SolverState state, SolverParameters parameters)
{
	const unsigned int N = input.numberOfImages;							// Number of block variables
	const unsigned int x = blockIdx.x;
	const unsigned int lane = threadIdx.x % WARP_SIZE;

	//float d = 0.0f;
	if (x > 0 && x < N)
	{
		float3 rot, trans;
		applyJTDevice(x, input, state, parameters, rot, trans, threadIdx.x, lane);			// A x p_k  => J^T x J x p_k 

		if (lane == 0)
		{
			atomicAdd(&state.d_Ap_XRot[x].x, rot.x);
			atomicAdd(&state.d_Ap_XRot[x].y, rot.y);
			atomicAdd(&state.d_Ap_XRot[x].z, rot.z);

			atomicAdd(&state.d_Ap_XTrans[x].x, trans.x);
			atomicAdd(&state.d_Ap_XTrans[x].y, trans.y);
			atomicAdd(&state.d_Ap_XTrans[x].z, trans.z);
		}
	}
}

__global__ void PCGStep_Kernel1b(SolverInput input, SolverState state, SolverParameters parameters)
{
	const unsigned int N = input.numberOfImages;								// Number of block variables
	const unsigned int x = blockIdx.x * blockDim.x + threadIdx.x;

	float d = 0.0f;
	if (x > 0 && x < N)
	{
		d = dot(state.d_pRot[x], state.d_Ap_XRot[x]) + dot(state.d_pTrans[x], state.d_Ap_XTrans[x]);		// x-th term of denominator of alpha
	}

	d = warpReduce(d);
	if (threadIdx.x % WARP_SIZE == 0)
	{
		atomicAdd(state.d_scanAlpha, d);
	}
}

__global__ void PCGStep_Kernel2(SolverInput input, SolverState state)
{
	const unsigned int N = input.numberOfImages;
	const unsigned int x = blockIdx.x * blockDim.x + threadIdx.x;

	const float dotProduct = state.d_scanAlpha[0];

	float b = 0.0f;
	if (x > 0 && x < N)
	{
		float alpha = 0.0f;
		if (dotProduct > FLOAT_EPSILON) alpha = state.d_rDotzOld[x] / dotProduct;		// update step size alpha

		state.d_deltaRot[x] = state.d_deltaRot[x] + alpha*state.d_pRot[x];			// do a decent step
		state.d_deltaTrans[x] = state.d_deltaTrans[x] + alpha*state.d_pTrans[x];	// do a decent step

		float3 rRot = state.d_rRot[x] - alpha*state.d_Ap_XRot[x];					// update residuum
		state.d_rRot[x] = rRot;														// store for next kernel call

		float3 rTrans = state.d_rTrans[x] - alpha*state.d_Ap_XTrans[x];				// update residuum
		state.d_rTrans[x] = rTrans;													// store for next kernel call

		float3 zRot = state.d_precondionerRot[x] * rRot;							// apply preconditioner M^-1
		state.d_zRot[x] = zRot;														// save for next kernel call

		float3 zTrans = state.d_precondionerTrans[x] * rTrans;						// apply preconditioner M^-1
		state.d_zTrans[x] = zTrans;													// save for next kernel call

		b = dot(zRot, rRot) + dot(zTrans, rTrans);									// compute x-th term of the nominator of beta
	}
	b = warpReduce(b);
	if (threadIdx.x % WARP_SIZE == 0)
	{
		atomicAdd(&state.d_scanAlpha[1], b);
	}
}

template<bool lastIteration>
__global__ void PCGStep_Kernel3(SolverInput input, SolverState state)
{
	const unsigned int N = input.numberOfImages;
	const unsigned int x = blockIdx.x * blockDim.x + threadIdx.x;

	if (x > 0 && x < N)
	{
		const float rDotzNew = state.d_scanAlpha[1];								// get new nominator
		const float rDotzOld = state.d_rDotzOld[x];								// get old denominator

		float beta = 0.0f;
		if (rDotzOld > FLOAT_EPSILON) beta = rDotzNew / rDotzOld;				// update step size beta

		state.d_rDotzOld[x] = rDotzNew;											// save new rDotz for next iteration
		state.d_pRot[x] = state.d_zRot[x] + beta*state.d_pRot[x];		// update decent direction
		state.d_pTrans[x] = state.d_zTrans[x] + beta*state.d_pTrans[x];		// update decent direction


		state.d_Ap_XRot[x] = make_float3(0.0f, 0.0f, 0.0f);
		state.d_Ap_XTrans[x] = make_float3(0.0f, 0.0f, 0.0f);

		if (lastIteration)
		{
			state.d_xRot[x] = state.d_xRot[x] + state.d_deltaRot[x];
			state.d_xTrans[x] = state.d_xTrans[x] + state.d_deltaTrans[x];
		}
	}
}

void PCGIteration(SolverInput& input, SolverState& state, SolverParameters& parameters, bool lastIteration, CUDATimer *timer)
{
	bool useSparse = parameters.weightSparse > 0.0f;
	bool useDense = parameters.weightDenseDepth > 0.0f;

	const unsigned int N = input.numberOfImages;	// Number of block variables

	// Do PCG step
	const int blocksPerGrid = (N + THREADS_PER_BLOCK - 1) / THREADS_PER_BLOCK;

	if (blocksPerGrid > THREADS_PER_BLOCK)
	{
		std::cout << "Too many variables for this block size. Maximum number of variables for two kernel scan: " << THREADS_PER_BLOCK*THREADS_PER_BLOCK << std::endl;
		while (1);
	}

	//if (timer) timer->startEvent("PCGIteration::applyJ");
	cutilSafeCall(cudaMemset(state.d_scanAlpha, 0, sizeof(float) * 2));

	const unsigned int Ncorr = input.numberOfCorrespondences;
	const int blocksPerGridCorr = (Ncorr + THREADS_PER_BLOCK - 1) / THREADS_PER_BLOCK;
	PCGStep_Kernel0 << <blocksPerGridCorr, THREADS_PER_BLOCK >> >(input, state, parameters);
#ifdef _DEBUG
	cutilSafeCall(cudaDeviceSynchronize());
	cutilCheckMsg(__FUNCTION__);
#endif
	//if (timer) timer->endEvent();

	//if (timer) timer->startEvent("PCGIteration::applyJTa");
	PCGStep_Kernel1a << < N, THREADS_PER_BLOCK_JT >> >(input, state, parameters);
#ifdef _DEBUG
	cutilSafeCall(cudaDeviceSynchronize());
	cutilCheckMsg(__FUNCTION__);
#endif
	//if (timer) timer->endEvent();

	//if (timer) timer->startEvent("PCGIteration::applyJTb");
	PCGStep_Kernel1b << <blocksPerGrid, THREADS_PER_BLOCK >> >(input, state, parameters);
#ifdef _DEBUG
	cutilSafeCall(cudaDeviceSynchronize());
	cutilCheckMsg(__FUNCTION__);
#endif
	//if (timer) timer->endEvent();

	//if (timer) timer->startEvent("PCGIteration::2");
	PCGStep_Kernel2 << <blocksPerGrid, THREADS_PER_BLOCK >> >(input, state);
#ifdef _DEBUG
	cutilSafeCall(cudaDeviceSynchronize());
	cutilCheckMsg(__FUNCTION__);
#endif
	//if (timer) timer->endEvent();

	//if (timer) timer->startEvent("PCGIteration::3");
	if (lastIteration) {
		PCGStep_Kernel3<true> << <blocksPerGrid, THREADS_PER_BLOCK >> >(input, state);
	}
	else {
		PCGStep_Kernel3<false> << <blocksPerGrid, THREADS_PER_BLOCK >> >(input, state);
	}

#ifdef _DEBUG
	cutilSafeCall(cudaDeviceSynchronize());
	cutilCheckMsg(__FUNCTION__);
#endif

	//if (timer) timer->endEvent();
}

/////////////////////////////////////////////////////////////////////////
// Apply Update
/////////////////////////////////////////////////////////////////////////

__global__ void ApplyLinearUpdateDevice(SolverInput input, SolverState state, SolverParameters parameters)
{
	const unsigned int N = input.numberOfImages; // Number of block variables
	const unsigned int x = blockIdx.x * blockDim.x + threadIdx.x;

	if (x > 0 && x < N) {
		state.d_xRot[x] = state.d_xRot[x] + state.d_deltaRot[x];
		state.d_xTrans[x] = state.d_xTrans[x] + state.d_deltaTrans[x];
	}
}

void ApplyLinearUpdate(SolverInput& input, SolverState& state, SolverParameters& parameters)
{
	const unsigned int N = input.numberOfImages; // Number of block variables
	ApplyLinearUpdateDevice << <(N + THREADS_PER_BLOCK - 1) / THREADS_PER_BLOCK, THREADS_PER_BLOCK >> >(input, state, parameters);
#ifdef _DEBUG
	cutilSafeCall(cudaDeviceSynchronize());
	cutilCheckMsg(__FUNCTION__);
#endif
}

////////////////////////////////////////////////////////////////////
// Main GN Solver Loop
////////////////////////////////////////////////////////////////////

extern "C" void solveBundlingStub(SolverInput& input, SolverState& state, SolverParameters& parameters, float* convergenceAnalysis, CUDATimer *timer)
{
	if (convergenceAnalysis) {
		float initialResidual = EvalResidual(input, state, parameters, timer);
		//printf("initial = %f\n", initialResidual);
		convergenceAnalysis[0] = initialResidual; // initial residual
	}
	//unsigned int idx = 0;

	for (unsigned int nIter = 0; nIter < parameters.nNonLinearIterations; nIter++)
	{
		BuildDenseDepthSystem(input, state, parameters, timer);
		Initialization(input, state, parameters, timer);

		//float linearResidual = EvalLinearRes(input, state, parameters);
		//linConvergenceAnalysis[idx++] = linearResidual;

		for (unsigned int linIter = 0; linIter < parameters.nLinIterations; linIter++)
		{
			PCGIteration(input, state, parameters, linIter == parameters.nLinIterations - 1, timer);

			//linearResidual = EvalLinearRes(input, state, parameters);
			//linConvergenceAnalysis[idx++] = linearResidual;
		}

		//ApplyLinearUpdate(input, state, parameters);	//this should be also done in the last PCGIteration

		if (convergenceAnalysis) {
			float residual = EvalResidual(input, state, parameters, timer);
			convergenceAnalysis[nIter + 1] = residual;
			//printf("[niter %d] %f\n", nIter, residual);
		}
	}
}

////////////////////////////////////////////////////////////////////
// build variables to correspondences lookup
////////////////////////////////////////////////////////////////////

__global__ void BuildVariablesToCorrespondencesTableDevice(EntryJ* d_correspondences, unsigned int numberOfCorrespondences, unsigned int maxNumCorrespondencesPerImage, int* d_variablesToCorrespondences, int* d_numEntriesPerRow)
{
	const unsigned int N = numberOfCorrespondences; // Number of block variables
	const unsigned int x = blockIdx.x * blockDim.x + threadIdx.x;

	if (x < N) {
		const EntryJ& corr = d_correspondences[x];
		if (corr.isValid()) {
			int offset = atomicAdd(&d_numEntriesPerRow[corr.imgIdx_i], 1); // may overflow - need to check when read
			if (offset < maxNumCorrespondencesPerImage)	d_variablesToCorrespondences[corr.imgIdx_i * maxNumCorrespondencesPerImage + offset] = x;

			offset = atomicAdd(&d_numEntriesPerRow[corr.imgIdx_j], 1); // may overflow - need to check when read
			if (offset < maxNumCorrespondencesPerImage)	d_variablesToCorrespondences[corr.imgIdx_j * maxNumCorrespondencesPerImage + offset] = x;
		}
	}
}

extern "C" void buildVariablesToCorrespondencesTableCUDA(EntryJ* d_correspondences, unsigned int numberOfCorrespondences, unsigned int maxNumCorrespondencesPerImage, int* d_variablesToCorrespondences, int* d_numEntriesPerRow, CUDATimer* timer)
{
	const unsigned int N = numberOfCorrespondences;

	if (timer) timer->startEvent(__FUNCTION__);

	BuildVariablesToCorrespondencesTableDevice << <(N + THREADS_PER_BLOCK - 1) / THREADS_PER_BLOCK, THREADS_PER_BLOCK >> >(d_correspondences, numberOfCorrespondences, maxNumCorrespondencesPerImage, d_variablesToCorrespondences, d_numEntriesPerRow);

#ifdef _DEBUG
	cutilSafeCall(cudaDeviceSynchronize());
	cutilCheckMsg(__FUNCTION__);
#endif

	if (timer) timer->endEvent();
}
