/*
 * WiVRn VR streaming
 * Copyright (C) 2022  Guillaume Meunier <guillaume.meunier@centraliens.net>
 * Copyright (C) 2022  Patrick Nicolas <patricknicolas@laposte.net>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

#include "video_encoder_x265.h"

#include "util/u_logging.h"
#include "utils/wivrn_vk_bundle.h"
#include "yuv_converter.h"
#include <stdexcept>

namespace xrt::drivers::wivrn
{

void VideoEncoderX265::ProcessCb(void * opaque, x265_nal * nal)
{
	VideoEncoderX265 * self = static_cast<VideoEncoderX265 *>(opaque);
	self->ProcessNal({nal->i_first_mb, nal->i_last_mb, std::vector<uint8_t>(nal->p_payload, nal->p_payload + nal->i_payload)});
}

void VideoEncoderX265::ProcessNal(pending_nal && nal)
{
	std::lock_guard<std::mutex> lock(mutex);
	if (nal.first_mb == next_mb)
	{
		next_mb = nal.last_mb + 1;
		SendData(nal.data, next_mb == num_mb);
	}
	else
	{
		InsertInPendingNal(std::move(nal));
	}
	while (!pending_nals.empty() && pending_nals.front().first_mb == next_mb)
	{
		next_mb = pending_nals.front().last_mb + 1;
		SendData(pending_nals.front().data, next_mb == num_mb);
		pending_nals.pop_front();
	}
}

void VideoEncoderX265::InsertInPendingNal(pending_nal && nal)
{
	auto it = std::lower_bound(pending_nals.begin(), pending_nals.end(), nal, [](const pending_nal & a, const pending_nal & b) { return a.first_mb < b.first_mb; });
	pending_nals.insert(it, std::move(nal));
}

VideoEncoderX265::VideoEncoderX265(
        wivrn_vk_bundle & vk,
        encoder_settings & settings,
        float fps)
{
	if (settings.encoder_name != "h265")
	{
		U_LOG_W("requested x265 encoder with codec != h265");
		settings.encoder_name = "h265";
	}

	// encoder requires width and height to be even
	settings.video_width += settings.video_width % 2;
	settings.video_height += settings.video_height % 2;
	chroma_width = settings.video_width / 2;

	rect = vk::Rect2D{
	        .offset = {
	                .x = settings.offset_x,
	                .y = settings.offset_y,
	        },
	        .extent = {
	                .width = settings.width,
	                .height = settings.height,
	        },
	};

	num_mb = ((settings.video_width + 15) / 16) * ((settings.video_height + 15) / 16);

	luma = buffer_allocation(
	        vk.device,
	        {
	                .size = vk::DeviceSize(settings.video_width * settings.video_height),
	                .usage = vk::BufferUsageFlagBits::eTransferDst,
	        },
	        {
	                .flags = VMA_ALLOCATION_CREATE_HOST_ACCESS_RANDOM_BIT,
	                .usage = VMA_MEMORY_USAGE_AUTO,
	        });
	chroma = buffer_allocation(
	        vk.device, {
	                           .size = vk::DeviceSize(settings.video_width * settings.video_height / 2),
	                           .usage = vk::BufferUsageFlagBits::eTransferDst,
	                   },
	        {
	                .flags = VMA_ALLOCATION_CREATE_HOST_ACCESS_RANDOM_BIT,
	                .usage = VMA_MEMORY_USAGE_AUTO,
	        });

	param = x265_param_alloc();
	x265_param_default_preset(param, "ultrafast", "zerolatency");
	param->bRepeatHeaders = 1;
	param->bAnnexB = 0;
	param->internalCsp = X265_CSP_I420;
	param->sourceWidth = settings.video_width;
	param->sourceHeight = settings.video_height;
	param->fpsNum = static_cast<uint32_t>(fps * 1'000'000);
	param->fpsDenom = 1'000'000;
	param->logLevel = X265_LOG_WARNING;
	param->keyframeMax = X265_KEYINT_MAX_INFINITE;
	param->rc.rateControlMode = X265_RC_ABR;
	param->rc.bitrate = settings.bitrate / 1000; // x265 uses kbit/s

	// VUI parameters
	param->vui.bEnableVideoFullRangeFlag = 1;
	settings.range = VK_SAMPLER_YCBCR_RANGE_ITU_FULL;
	param->vui.colorPrimaries = 1; // BT.709
	param->vui.matrixCoeffs = 1;   // BT.709
	settings.color_model = VK_SAMPLER_YCBCR_MODEL_CONVERSION_YCBCR_709;
	param->vui.transferCharacteristics = 13; // sRGB
	param->vui.sarWidth = settings.width;
	param->vui.sarHeight = settings.height;

	enc = x265_encoder_open(param);
	if (!enc)
	{
		throw std::runtime_error("failed to create x265 encoder");
	}

	pic_in = x265_picture_alloc();
	x265_picture_init(param, pic_in);
	pic_in->colorSpace = X265_CSP_I420;
	pic_in->planes[0] = static_cast<uint8_t *>(luma.map());
	pic_in->planes[1] = static_cast<uint8_t *>(chroma.map());
	pic_in->planes[2] = static_cast<uint8_t *>(chroma.map()) + chroma_width * settings.video_height / 2;
	pic_in->stride[0] = settings.video_width;
	pic_in->stride[1] = chroma_width;
	pic_in->stride[2] = chroma_width;
}

void VideoEncoderX265::PresentImage(yuv_converter & src_yuv, vk::raii::CommandBuffer & cmd_buf)
{
	cmd_buf.copyImageToBuffer(
	        src_yuv.luma,
	        vk::ImageLayout::eTransferSrcOptimal,
	        luma,
	        vk::BufferImageCopy{
	                .bufferRowLength = chroma_width * 2,
	                .imageSubresource = {
	                        .aspectMask = vk::ImageAspectFlagBits::eColor,
	                        .layerCount = 1,
	                },
	                .imageOffset = {
	                        .x = rect.offset.x,
	                        .y = rect.offset.y,
	                },
	                .imageExtent = {
	                        .width = rect.extent.width,
	                        .height = rect.extent.height,
	                        .depth = 1,
	                }});
	cmd_buf.copyImageToBuffer(
	        src_yuv.chroma,
	        vk::ImageLayout::eTransferSrcOptimal,
	        chroma,
	        vk::BufferImageCopy{
	                .bufferRowLength = chroma_width,
	                .imageSubresource = {
	                        .aspectMask = vk::ImageAspectFlagBits::eColor,
	                        .layerCount = 1,
	                },
	                .imageOffset = {
	                        .x = rect.offset.x / 2,
	                        .y = rect.offset.y / 2,
	                },
	                .imageExtent = {
	                        .width = rect.extent.width / 2,
	                        .height = rect.extent.height / 2,
	                        .depth = 1,
	                }});
}

void VideoEncoderX265::Encode(bool idr, std::chrono::steady_clock::time_point pts)
{
	pic_in->sliceType = idr ? X265_TYPE_IDR : X265_TYPE_P;
	pic_in->pts = pts.time_since_epoch().count();
	next_mb = 0;
	assert(pending_nals.empty());

	x265_nal * nals;
	uint32_t num_nals;
	int frame_size = x265_encoder_encode(enc, &nals, &num_nals, pic_in, pic_out);

	if (frame_size < 0)
	{
		U_LOG_W("x265_encoder_encode failed: %d", frame_size);
		return;
	}

	for (uint32_t i = 0; i < num_nals; ++i)
	{
		ProcessCb(this, &nals[i]);
	}

	if (next_mb != num_mb)
	{
		U_LOG_W("unexpected macroblock count: %d", next_mb);
	}
}

VideoEncoderX265::~VideoEncoderX265()
{
	x265_picture_free(pic_in);
	x265_encoder_close(enc);
	x265_param_free(param);
}

} // namespace xrt::drivers::wivrn
