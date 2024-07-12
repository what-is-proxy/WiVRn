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

VideoEncoderX265::VideoEncoderX265(
        wivrn_vk_bundle & vk,
        encoder_settings & settings,
        float fps)
{
	if (settings.codec != h265)
	{
		U_LOG_W("requested x265 encoder with codec != h265");
		settings.codec = h265;
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

	x265_param_default_preset(&param, "ultrafast", "zerolatency");
	param.bEnableWavefront = 0;
	param.maxSlices = 32;
	param.sourceWidth = settings.video_width;
	param.sourceHeight = settings.video_height;
	param.fpsNum = static_cast<uint32_t>(fps * 1'000'000);
	param.fpsDenom = 1'000'000;
	param.bRepeatHeaders = 1;
	param.bEnableAccessUnitDelimiters = 0;
	param.keyframeMax = -1;

	// colour definitions, actually ignored by decoder
	param.vui.bEnableVideoFullRangeFlag = 1;
	settings.range = VK_SAMPLER_YCBCR_RANGE_ITU_FULL;
	param.vui.colorPrimaries = 1; // BT.709
	param.vui.matrixCoeffs = 1;   // BT.709
	settings.color_model = VK_SAMPLER_YCBCR_MODEL_CONVERSION_YCBCR_709;
	param.vui.transferCharacteristics = 13; // sRGB

	param.vui.sarWidth = settings.width;
	param.vui.sarHeight = settings.height;
	param.rc.rateControlMode = X265_RC_ABR;
	param.rc.bitrate = settings.bitrate / 1000; // x265 uses kbit/s

	enc = x265_encoder_open(&param);
	if (!enc)
	{
		throw std::runtime_error("Failed to create x265 encoder");
	}

	pic_in = x265_picture_alloc();
	x265_picture_init(&param, pic_in);
	pic_in->userData = this;
	pic_in->colorSpace = X265_CSP_I420;
	pic_in->planes[0] = static_cast<uint8_t *>(luma.map());
	pic_in->planes[1] = static_cast<uint8_t *>(chroma.map());
	pic_in->stride[0] = settings.video_width;
	pic_in->stride[1] = settings.video_width;
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
	x265_nal * nals;
	uint32_t num_nal;
	pic_in->sliceType = idr ? X265_TYPE_IDR : X265_TYPE_AUTO;
	pic_in->pts = pts.time_since_epoch().count();

	int size = x265_encoder_encode(enc, &nals, &num_nal, pic_in, nullptr);
	if (size < 0)
	{
		U_LOG_W("x265_encoder_encode failed: %d", size);
		return;
	}

	for (uint32_t i = 0; i < num_nal; i++)
	{
		std::vector<uint8_t> data(nals[i].payload, nals[i].payload + nals[i].sizeBytes);
		bool is_last = (i == num_nal - 1);
		SendData(data, is_last);
	}
}

VideoEncoderX265::~VideoEncoderX265()
{
	x265_picture_free(pic_in);
	x265_encoder_close(enc);
}

} // namespace xrt::drivers::wivrn
