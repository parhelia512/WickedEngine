#include "imageHF.hlsli"

float4 main(VertextoPixel input) : SV_TARGET
{
	SamplerState sam = bindless_samplers[descriptor_index(image.sampler_index)];

	const half hdr_scaling = unpack_half2(image.hdr_scaling_aspect).x;
	const half canvas_aspect = unpack_half2(image.hdr_scaling_aspect).y;
	const half border_soften = unpack_half2(image.bordersoften_saturation).x;
	const half saturation = unpack_half2(image.bordersoften_saturation).y;

	float4 uvsets = input.compute_uvs();

	half4 color = unpack_half4(image.packed_color);
	[branch]
	if (image.texture_base_index >= 0)
	{
		half4 tex = 0;
		
		[branch]
		if (image.flags & IMAGE_FLAG_CUBEMAP_BASE)
		{
			float3 cube_dir = uv_to_cubemap_cross(uvsets.xy);
			if (any(cube_dir))
			{
				tex = bindless_cubemaps_half4[descriptor_index(image.texture_base_index)].SampleLevel(sam, cube_dir, 0);
			}
		}
		else if(image.flags & IMAGE_FLAG_TEXTURE1D_BASE)
		{
			tex = bindless_textures1D_half4[descriptor_index(image.texture_base_index)].Sample(sam, uvsets.x);
		}
		else
		{
			tex = bindless_textures_half4[descriptor_index(image.texture_base_index)].Sample(sam, uvsets.xy);
		}

		if (image.flags & IMAGE_FLAG_EXTRACT_NORMALMAP)
		{
			tex.rgb = tex.rgb * 2 - 1;
		}

		color *= tex;
	}

	half4 mask = 1;
	[branch]
	if (image.texture_mask_index >= 0)
	{
		mask = bindless_textures_half4[descriptor_index(image.texture_mask_index)].Sample(sam, uvsets.zw);
	}

	const half2 mask_alpha_range = unpack_half2(image.mask_alpha_range);
	mask.a = smoothstep(mask_alpha_range.x, mask_alpha_range.y, mask.a);
	
	float2 uv_screen = input.uv_screen();
	
	if(image.flags & IMAGE_FLAG_DISTORTION_MASK)
	{
		// Only mask alpha is used for multiplying, rg is used for distorting background:
		color.a *= mask.a;
		uv_screen += mask.rg * 2 - 1;
	}
	else
	{
		color *= mask;
	}

	[branch]
	if (image.texture_background_index >= 0)
	{
		Texture2D<half4> backgroundTexture = bindless_textures_half4[descriptor_index(image.texture_background_index)];
		const half3 background = backgroundTexture.Sample(sam, uv_screen).rgb;
		color = half4(lerp(background, color.rgb, color.a), mask.a);
	}

	[branch]
	if (image.flags & IMAGE_FLAG_HIGHLIGHT)
	{
		const half2 uv = half2(uv_screen) * half2(canvas_aspect, 1);
		const half2 highlight_xy = unpack_half2(image.highlight_xy);
		const half4 highlight_color_spread = unpack_half4(image.highlight_color_spread);
		const half3 highlight_color = highlight_color_spread.xyz;
		const half highlight_spread = highlight_color_spread.w;
		color.rgb = lerp(color.rgb, highlight_color, smoothstep(highlight_spread, 0, saturate(distance(uv, highlight_xy))));
	}

	[branch]
	if (image.flags & IMAGE_FLAG_GRADIENT_LINEAR)
	{
		const half2 a = unpack_half2(image.gradient_uv_start);
		const half2 b = unpack_half2(image.gradient_uv_end);
		const half dist = length(b - a);
		const half2 uv = uvsets.xy;
		const half2 point_on_line = closest_point_on_segment(a, b, uv);
		const half uv_distance = length(point_on_line - a);
		const half gradient = smoothstep(0.0, 1.0, 1 - saturate(inverse_lerp(half(0.0), dist, uv_distance)));
		const half4 gradient_color = unpack_half4(image.gradient_color);
		color.rgb = lerp(color.rgb, gradient_color.rgb, gradient * gradient_color.a);
	}
	else if (image.flags & IMAGE_FLAG_GRADIENT_LINEAR_REFLECTED)
	{
		const half2 a = unpack_half2(image.gradient_uv_start);
		const half2 b = unpack_half2(image.gradient_uv_end);
		const half dist = length(b - a);
		const half2 uv = uvsets.xy;
		const half2 point_on_line = closest_point_on_line(a, b, uv);
		const half uv_distance = length(point_on_line - a);
		const half gradient = smoothstep(0.0, 1.0, 1 - saturate(inverse_lerp(half(0.0), dist, uv_distance)));
		const half4 gradient_color = unpack_half4(image.gradient_color);
		color.rgb = lerp(color.rgb, gradient_color.rgb, gradient * gradient_color.a);
	}
	else if (image.flags & IMAGE_FLAG_GRADIENT_CIRCULAR)
	{
		const half2 a = unpack_half2(image.gradient_uv_start);
		const half2 b = unpack_half2(image.gradient_uv_end);
		const half dist = length(b - a);
		const half2 uv = uvsets.xy;
		const half uv_distance = clamp(length(uv - a), 0, dist);
		const half gradient = smoothstep(0.0, 1.0, 1 - saturate(inverse_lerp(half(0.0), dist, uv_distance)));
		const half4 gradient_color = unpack_half4(image.gradient_color);
		color.rgb = lerp(color.rgb, gradient_color.rgb, gradient * gradient_color.a);
	}
	
	[branch]
	if (border_soften > 0)
	{
		const half edge = max(abs(input.edge.x), abs(input.edge.y));
		color.a *= smoothstep(0, border_soften, 1 - edge);
	}

	[branch]
	if (image.angular_softness_mad > 0)
	{
		const half2 angular_softness_direction = unpack_half2(image.angular_softness_direction);
		const half2 direction = normalize(uvsets.xy - 0.5);
		half dp = dot(direction, angular_softness_direction);
		if (image.flags & IMAGE_FLAG_ANGULAR_DOUBLESIDED)
		{
			dp = abs(dp);
		}
		else
		{
			dp = saturate(dp);
		}
		const half2 angular_softness_mad = unpack_half2(image.angular_softness_mad);
		half angular = saturate(mad(dp, angular_softness_mad.x, angular_softness_mad.y));
		if (image.flags & IMAGE_FLAG_ANGULAR_INVERSE)
		{
			angular = 1 - angular;
		}
		angular = smoothstep(0, 1, angular);
		color.a *= angular;
	}
	
	color.rgb = mul(saturationMatrix(saturation), color.rgb);
	
	[branch]
	if (image.flags & IMAGE_FLAG_OUTPUT_COLOR_SPACE_LINEAR)
	{
		color.rgb = RemoveSRGBCurve_Fast(color.rgb);
		color.rgb *= hdr_scaling;
	}
	
	[branch]
	if (image.flags & IMAGE_FLAG_OUTPUT_COLOR_SPACE_HDR10_ST2084)
	{
		// https://github.com/microsoft/DirectX-Graphics-Samples/blob/master/Samples/Desktop/D3D12HDR/src/presentPS.hlsl
		const half referenceWhiteNits = 80.0;
		const half st2084max = 10000.0;
		const half hdrScalar = referenceWhiteNits / st2084max;
		// The input is in Rec.709, but the display is Rec.2020
		color.rgb = REC709toREC2020(color.rgb);
		// Apply the ST.2084 curve to the result.
		color.rgb = ApplyREC2084Curve(color.rgb * hdrScalar);
	}

	return color;
}
