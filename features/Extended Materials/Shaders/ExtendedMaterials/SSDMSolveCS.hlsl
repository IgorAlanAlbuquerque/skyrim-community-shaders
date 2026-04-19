// SSDM: hierarchical init + damped Picard fixed-point on mip0 displacement field.
// Writes absolute normalized fetch UV (same basis as Lighting ViewToUV + DR + stereo).
// .z = 1 when no iterate required clamping into [0,1] (else composite must not remap — silhouette smear).
// .w = forward-pass SSDM coverage (displacement RT mip0 .z); composite requires .z and .w.

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
SamplerState LinearSampler : register(s0);
RWTexture2D<float4> OutAbsUV : register(u0);

[numthreads(8, 8, 1)]
void main(uint3 dtid : SV_DispatchThreadID)
{
	if (any(float2(dtid.xy) >= FullDim))
		return;

	float2 uv = (float2(dtid.xy) + 0.5) * RcpFullDim;
	float coverage = DuvPyramid.Load(int3(int2(dtid.xy), 0)).z;

	float coarseMip = max(0.0, float(NumMips - 1));
	float2 tCoarse = uv + DuvPyramid.SampleLevel(LinearSampler, uv, coarseMip).xy;
	bool ssdmValid = all(saturate(tCoarse) == tCoarse);
	float2 t = saturate(tCoarse);

	int iters = min(max(NumIters, 1), 16);
	[loop]
	for (int i = 0; i < iters; ++i) {
		float2 d = DuvPyramid.SampleLevel(LinearSampler, t, 0).xy;
		float2 picard = uv + d;
		float2 delta = picard - t;
		delta = clamp(delta, -MaxStepUv.xx, MaxStepUv.xx);
		float2 next = t + delta;
		next = lerp(t, next, Damping);
		ssdmValid = ssdmValid && all(saturate(next) == next);
		t = saturate(next);
	}

	float validZ = ssdmValid ? 1.0 : 0.0;
	OutAbsUV[dtid.xy] = float4(t.xy, validZ, coverage);
}
