// Verification tool: finds NDI sources and reports what one of them is actually putting
// on the wire — resolution, rate, FourCC and, for HX, the exact compressed payload size.
//
//   ndi_probe                          list sources
//   ndi_probe <substring> [s]           receive from the first matching source
//   ndi_probe <substring> [s] <out.png> also decode and save a frame, which is how the
//                                       orientation of the delivered image is checked
//
// Built by Tools/build_probe.sh; not part of the app.
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <string>
#include <chrono>
#include <ImageIO/ImageIO.h>
#include <CoreGraphics/CoreGraphics.h>
#include <Processing.NDI.Advanced.h>

// Lists the NAL unit types in an Annex B buffer. Counting the keyframe *flag* only shows
// what the sender claimed; a receiver that has lost sync recovers only if the bitstream
// really carries an IDR and the parameter sets to decode it.
static std::string nal_types(const uint8_t* data, uint32_t size, bool hevc)
{
	std::string out;
	uint32_t i = 0;
	while (i + 4 <= size) {
		// Start codes are 00 00 01 or 00 00 00 01.
		if (data[i] == 0 && data[i + 1] == 0 && (data[i + 2] == 1 || (data[i + 2] == 0 && data[i + 3] == 1))) {
			uint32_t header = i + (data[i + 2] == 1 ? 3 : 4);
			if (header >= size) break;
			int type = hevc ? ((data[header] >> 1) & 0x3f) : (data[header] & 0x1f);
			const char* name = "";
			if (hevc) {
				if (type == 32) name = "VPS"; else if (type == 33) name = "SPS";
				else if (type == 34) name = "PPS"; else if (type >= 16 && type <= 21) name = "IDR/IRAP";
				else if (type <= 9) name = "slice";
			} else {
				if (type == 7) name = "SPS"; else if (type == 8) name = "PPS";
				else if (type == 5) name = "IDR"; else if (type == 1) name = "slice";
				else if (type == 6) name = "SEI";
			}
			if (!out.empty()) out += " ";
			out += std::to_string(type);
			if (*name) { out += "("; out += name; out += ")"; }
			i = header + 1;
			continue;
		}
		i++;
	}
	return out.empty() ? "none" : out;
}

static std::string fourcc(uint32_t value)
{
	char text[5] = {char(value & 0xff), char((value >> 8) & 0xff),
	                char((value >> 16) & 0xff), char((value >> 24) & 0xff), 0};
	for (int i = 0; i < 4; i++)
		if (text[i] < 32 || text[i] > 126) text[i] = '?';
	return text;
}

int main(int argc, char* argv[])
{
	if (!NDIlib_initialize()) { printf("NDIlib_initialize failed\n"); return 1; }

	NDIlib_find_create_t find_desc;
	find_desc.show_local_sources = true;
	NDIlib_find_instance_t finder = NDIlib_find_create_v2(&find_desc);
	if (!finder) { printf("could not create finder\n"); return 1; }

	printf("searching for NDI sources…\n");
	NDIlib_find_wait_for_sources(finder, 4000);
	uint32_t count = 0;
	const NDIlib_source_t* sources = NDIlib_find_get_current_sources(finder, &count);

	for (uint32_t i = 0; i < count; i++)
		printf("  [%u] %s   (%s)\n", i, sources[i].p_ndi_name, sources[i].p_url_address);
	if (count == 0) printf("  none found\n");

	if (argc < 2) { NDIlib_find_destroy(finder); NDIlib_destroy(); return 0; }

	const NDIlib_source_t* target = nullptr;
	for (uint32_t i = 0; i < count; i++)
		if (strstr(sources[i].p_ndi_name, argv[1])) { target = &sources[i]; break; }
	if (!target) { printf("\nno source matching \"%s\"\n", argv[1]); NDIlib_find_destroy(finder); NDIlib_destroy(); return 1; }

	const int seconds = (argc > 2) ? atoi(argv[2]) : 5;
	const char* png_path = (argc > 3 && argv[3][0]) ? argv[3] : nullptr;
	// 4th argument "low" asks for the proxy stream. For SpeedHQ the NDI library generates
	// that itself; for compressed (HX) senders the application must supply it, so this is
	// how to find out whether we do.
	const bool want_low = (argc > 4) && (strcmp(argv[4], "low") == 0);
	printf("\nreceiving from \"%s\" for %d s…\n", target->p_ndi_name, seconds);

	NDIlib_recv_create_v3_t recv_desc;
	recv_desc.source_to_connect_to = *target;
	// Passthrough, so the FourCC below is the sender's own format rather than whatever
	// the receiver decoded it into. Saving a PNG needs pixels instead, so that mode asks
	// for BGRA and gives up the FourCC reporting.
	recv_desc.color_format = png_path ? NDIlib_recv_color_format_BGRX_BGRA
	                                  : (NDIlib_recv_color_format_e)NDIlib_recv_color_format_ex_compressed_v4;
	recv_desc.bandwidth = want_low ? NDIlib_recv_bandwidth_lowest : NDIlib_recv_bandwidth_highest;
	printf("requesting %s bandwidth\n", want_low ? "LOWEST (proxy)" : "highest");
	NDIlib_recv_instance_t recv = NDIlib_recv_create_v3(&recv_desc);
	if (!recv) { printf("could not create receiver\n"); return 1; }

	int frames = 0, keyframes = 0, xres = 0, yres = 0, rateN = 0, rateD = 1;
	double first_keyframe_at = -1;
	uint64_t bytes = 0;
	uint32_t format = 0;

	// Wall clock, not an iteration count: capture returns as soon as a frame is ready,
	// so counting a fixed interval per call would understate the frame rate badly.
	const auto start = std::chrono::steady_clock::now();
	auto elapsed_seconds = [&] {
		return std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
	};

	while (elapsed_seconds() < seconds) {
		NDIlib_video_frame_v2_t video;
		NDIlib_frame_type_e type = NDIlib_recv_capture_v2(recv, &video, nullptr, nullptr, 100);
		if (type != NDIlib_frame_type_video) continue;

		// The moment the format changes at the receiver. If undecodable frames of the new
		// codec arrive before its first keyframe, that gap is the corruption window.
		if ((uint32_t)video.FourCC != format && frames > 0) {
			printf("  format changed to %s at %.2f s\n", fourcc((uint32_t)video.FourCC).c_str(), elapsed_seconds());
			fflush(stdout);
		}
		frames++;
		xres = video.xres; yres = video.yres;
		rateN = video.frame_rate_N; rateD = video.frame_rate_D;
		format = (uint32_t)video.FourCC;

		if (png_path && frames == 1 && video.p_data) {
			// The first decoded frame, written exactly as delivered.
			CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
			CGContextRef ctx = CGBitmapContextCreate(
				video.p_data, video.xres, video.yres, 8, video.line_stride_in_bytes, space,
				kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
			CGImageRef image = CGBitmapContextCreateImage(ctx);
			CFStringRef path = CFStringCreateWithCString(NULL, png_path, kCFStringEncodingUTF8);
			CFURLRef url = CFURLCreateWithFileSystemPath(NULL, path, kCFURLPOSIXPathStyle, false);
			CGImageDestinationRef dest = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
			CGImageDestinationAddImage(dest, image, NULL);
			CGImageDestinationFinalize(dest);
			CFRelease(dest); CFRelease(url); CFRelease(path);
			CGImageRelease(image); CGContextRelease(ctx); CGColorSpaceRelease(space);
			printf("  wrote %s (first decoded frame, %dx%d)\n", png_path, video.xres, video.yres);
		}

		if (!png_path && video.p_data && video.data_size_in_bytes >= (int)sizeof(NDIlib_compressed_packet_t)) {
			// Compressed frames arrive with the packet header in front of the bitstream.
			const NDIlib_compressed_packet_t* packet = (const NDIlib_compressed_packet_t*)video.p_data;
			if (packet->version == sizeof(NDIlib_compressed_packet_t)) {
				bytes += packet->data_size + packet->extra_data_size;
				if (packet->flags & 1) {
					keyframes++;
					if (first_keyframe_at < 0) first_keyframe_at = elapsed_seconds();
					if (keyframes <= 3) {
						const bool hevc = packet->fourCC == NDIlib_compressed_FourCC_type_HEVC;
						const uint8_t* payload = video.p_data + packet->version;
						printf("  keyframe %d at %.2f s: data %u B [%s], extra %u B [%s]\n",
						       keyframes, elapsed_seconds(), packet->data_size,
						       nal_types(payload, packet->data_size, hevc).c_str(),
						       packet->extra_data_size,
						       packet->extra_data_size
						           ? nal_types(payload + packet->data_size, packet->extra_data_size, hevc).c_str()
						           : "none");
						fflush(stdout);
					}
				}
			} else {
				bytes += video.data_size_in_bytes;
			}
		}
		NDIlib_recv_free_video_v2(recv, &video);
	}

	const double measured = elapsed_seconds();
	printf("\n  frames      %d  (%.1f fps over %.1f s)\n", frames, frames / measured, measured);
	printf("  resolution  %d x %d\n", xres, yres);
	printf("  declared    %d/%d = %.3f fps\n", rateN, rateD, rateD ? double(rateN) / rateD : 0.0);
	printf("  FourCC      %s (0x%08x)\n", fourcc(format).c_str(), format);
	if (keyframes) {
		printf("  keyframes   %d  (%.2f/s, first at %.2f s after connecting)\n",
		       keyframes, keyframes / measured, first_keyframe_at);
	}
	if (bytes) printf("  payload     %.2f Mbps measured at the receiver\n", bytes * 8.0 / measured / 1e6);

	NDIlib_recv_destroy(recv);
	NDIlib_find_destroy(finder);
	NDIlib_destroy();
	return frames > 0 ? 0 : 2;
}
