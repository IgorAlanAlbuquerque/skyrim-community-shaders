// SSDM: hierarchical init + damped Picard fixed-point on mip0 displacement field.
// Writes absolute normalized fetch UV (same basis as Lighting ViewToUV + DR + stereo).
// .z = 1 only when every iterate stays strictly inside the tile (inset margin — rejects border/silhouette smear).
// .w = forward-pass SSDM coverage (displacement RT mip0 .z); composite requires .z and .w.

static const float kSSDMUvInteriorEps = 0.002;
static const float kSSDMMaxSolveUvStride = 0.34;

bool SSDM_InStrictTile(float2 q)
{
	return all(q > kSSDMUvInteriorEps.xx && q < (1.0 - kSSDMUvInteriorEps).xx);
}

cbuffer SSDMSolveCB : register(b0)
{
	float2 FullDim;
	float2 RcpFullDim;
	int NumMips;
	int NumIters;
	float MaxStepUv;
	float Damping;
};

Texture2D<float4> DuvPyramid : register(t0);
SamplerState PointSampler : register(s0);
RWTexture2D<float4> OutAbsUV : register(u0);

[numthreads(8, 8, 1)]
void main(uint3 dtid : SV_DispatchThreadID)
{
	if (any(float2(dtid.xy) >= FullDim))
		return;

	float2 uv = (float2(dtid.xy) + 0.5) * RcpFullDim;
	float coverage = DuvPyramid.Load(int3(int2(dtid.xy), 0)).z;

	float coarseMip = max(0.0, float(NumMips - 1));
	// Point mip: linear would blend duv across surface/sky and silhouette edges (same failure mode as mip0 bilinear).
	float2 tCoarse = uv + DuvPyramid.SampleLevel(PointSampler, uv, coarseMip).xy;
	bool ssdmValid = SSDM_InStrictTile(tCoarse);
	float2 t = saturate(tCoarse);

	int iters = min(max(NumIters, 1), 16);
	[loop]
	for (int i = 0; i < iters; ++i) {
		// Point mip0: bilinear would blend duv (and coverage in .z) across surface/sky edges → stray "almost valid" pixels.
		float2 d = DuvPyramid.SampleLevel(PointSampler, t, 0).xy;
		float2 picard = uv + d;
		ssdmValid = ssdmValid && SSDM_InStrictTile(picard);
		float2 delta = picard - t;
		delta = clamp(delta, -MaxStepUv.xx, MaxStepUv.xx);
		float2 next = t + delta;
		next = lerp(t, next, Damping);
		ssdmValid = ssdmValid && all(saturate(next) == next) && SSDM_InStrictTile(next);
		t = saturate(next);
	}

	ssdmValid = ssdmValid && SSDM_InStrictTile(t);
	float2 solveHop = t - uv;
	ssdmValid = ssdmValid && (dot(solveHop, solveHop) <= kSSDMMaxSolveUvStride * kSSDMMaxSolveUvStride);
	ssdmValid = ssdmValid && (coverage > 0.5);
	float validZ = ssdmValid ? 1.0 : 0.0;
	OutAbsUV[dtid.xy] = float4(t.xy, validZ, coverage);
}
