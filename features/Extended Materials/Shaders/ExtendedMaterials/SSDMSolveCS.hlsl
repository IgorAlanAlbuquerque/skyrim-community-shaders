// SSDM: hierarchical init + damped Picard fixed-point on mip0 displacement field.
// Writes absolute normalized fetch UV in full buffer [0,1] (matches DeferredComposite remapCoord).
// SurfaceWidth/Height = dynamic render extent (matches Util::GetScreenDispatchCount + upscaling / DRS).
// .z = 1 only when every iterate stays strictly inside the tile (inset margin — rejects border/silhouette smear).
// .w = forward-pass SSDM coverage (displacement RT mip0 .z); composite requires .z and .w.

static const float kSSDMUvInteriorEps = 0.002;
static const float kSSDMMaxSolveUvStride = 0.34;

bool SSDM_InStrictTile(float2 q)
{
	return all(q > kSSDMUvInteriorEps.xx && q < (1.0 - kSSDMUvInteriorEps).xx);
}

// Scalar-only layout — must match ExtendedMaterials::SSDMSolveCB in ExtendedMaterials.h (64 bytes).
cbuffer SSDMSolveCB : register(b0)
{
	float SurfaceWidth;
	float SurfaceHeight;
	float BufferWidth;
	float BufferHeight;
	float RcpBufferWidth;
	float RcpBufferHeight;
	float MaxStepUv;
	float Damping;
	int NumMips;
	int NumIters;
	int Pad0;
	int Pad1;
	int Pad2;
	int Pad3;
	int Pad4;
	int Pad5;
};

Texture2D<float4> DuvPyramid : register(t0);
SamplerState PointSampler : register(s0);
RWTexture2D<float4> OutAbsUV : register(u0);

[numthreads(8, 8, 1)]
void main(uint3 dtid : SV_DispatchThreadID)
{
	if (float(dtid.x) >= SurfaceWidth || float(dtid.y) >= SurfaceHeight)
		return;

	float2 rcpBufferDim = float2(RcpBufferWidth, RcpBufferHeight);
	float2 uvBuf = (float2(dtid.xy) + 0.5) * rcpBufferDim;

	float coverage = DuvPyramid.Load(int3(int2(dtid.xy), 0)).z;

	float coarseMip = max(0.0, float(NumMips - 1));
	float2 tCoarse = uvBuf + DuvPyramid.SampleLevel(PointSampler, uvBuf, coarseMip).xy;
	bool ssdmValid = SSDM_InStrictTile(tCoarse);
	float2 t = saturate(tCoarse);

	float maxStepUv = MaxStepUv;
	float damping = Damping;

	int iters = min(max(NumIters, 1), 16);
	[loop]
	for (int i = 0; i < iters; ++i) {
		float2 d = DuvPyramid.SampleLevel(PointSampler, t, 0).xy;
		float2 picard = uvBuf + d;
		ssdmValid = ssdmValid && SSDM_InStrictTile(picard);
		float2 delta = picard - t;
		delta = clamp(delta, -maxStepUv.xx, maxStepUv.xx);
		float2 next = t + delta;
		next = lerp(t, next, damping);
		ssdmValid = ssdmValid && all(saturate(next) == next) && SSDM_InStrictTile(next);
		t = saturate(next);
	}

	ssdmValid = ssdmValid && SSDM_InStrictTile(t);
	float2 solveHop = t - uvBuf;
	ssdmValid = ssdmValid && (dot(solveHop, solveHop) <= kSSDMMaxSolveUvStride * kSSDMMaxSolveUvStride);
	ssdmValid = ssdmValid && (coverage > 0.5);
	float validZ = ssdmValid ? 1.0 : 0.0;

	OutAbsUV[int2(dtid.xy)] = float4(t.xy, validZ, coverage);
}
