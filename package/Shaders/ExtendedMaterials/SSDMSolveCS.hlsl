// SSDM: hierarchical init + damped Picard fixed-point on mip0 displacement field.
// Writes absolute normalized fetch UV (same basis as Lighting ViewToUV + DR + stereo).

cbuffer SSDMSolveCB : register(b0)
{
	float2 FullDim;
	float2 RcpFullDim;
	int NumMips;
	int NumIters;
	float MaxStepUv;
	float Damping;
};

Texture2D<float2> DuvPyramid : register(t0);
SamplerState LinearSampler : register(s0);
RWTexture2D<float2> OutAbsUV : register(u0);

[numthreads(8, 8, 1)]
void main(uint3 dtid : SV_DispatchThreadID)
{
	if (any(float2(dtid.xy) >= FullDim))
		return;

	float2 uv = (float2(dtid.xy) + 0.5) * RcpFullDim;

	float coarseMip = max(0.0, float(NumMips - 1));
	float2 t = uv + DuvPyramid.SampleLevel(LinearSampler, uv, coarseMip).xy;
	t = saturate(t);

	int iters = min(max(NumIters, 1), 8);
	[loop]
	for (int i = 0; i < iters; ++i) {
		float2 d = DuvPyramid.SampleLevel(LinearSampler, t, 0).xy;
		float2 picard = uv + d;
		float2 delta = picard - t;
		delta = clamp(delta, -MaxStepUv.xx, MaxStepUv.xx);
		float2 next = t + delta;
		next = lerp(t, next, Damping);
		t = saturate(next);
	}

	OutAbsUV[dtid.xy] = t;
}
