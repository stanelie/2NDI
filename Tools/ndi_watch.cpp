// Stays connected to an NDI source and reports, minute by minute, how many frames it is
// actually receiving.
//
// This exists because the trial expiry cannot be trusted to announce itself. The
// user-visible symptom is that receivers stop getting video while the sender still reports
// success, so the honest measurement is taken at the receiver: watch the frame rate and
// see the minute it goes to zero. It also keeps a connection open, which the sender-side
// soak needs — a source with no receiver is not transmitting at all.
//
//   ndi_watch <name substring> [minutes]
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <chrono>
#include <Processing.NDI.Advanced.h>

int main(int argc, char* argv[])
{
	if (argc < 2) { printf("usage: ndi_watch <name substring> [minutes]\n"); return 1; }
	const char* wanted = argv[1];
	const double minutes = (argc > 2) ? atof(argv[2]) : 40.0;

	if (!NDIlib_initialize()) { printf("NDIlib_initialize failed\n"); return 1; }

	NDIlib_find_create_t find_desc;
	find_desc.show_local_sources = true;
	NDIlib_find_instance_t finder = NDIlib_find_create_v2(&find_desc);
	if (!finder) { printf("could not create the finder\n"); return 1; }

	const NDIlib_source_t* target = nullptr;
	uint32_t count = 0;
	for (int attempt = 0; attempt < 20 && !target; attempt++) {
		NDIlib_find_wait_for_sources(finder, 1000);
		const NDIlib_source_t* sources = NDIlib_find_get_current_sources(finder, &count);
		for (uint32_t i = 0; i < count; i++)
			if (strstr(sources[i].p_ndi_name, wanted)) { target = &sources[i]; break; }
	}
	if (!target) { printf("no source matching \"%s\"\n", wanted); return 1; }
	printf("watching \"%s\" for %.0f min\n", target->p_ndi_name, minutes);
	fflush(stdout);

	NDIlib_recv_create_v3_t recv_desc;
	recv_desc.source_to_connect_to = *target;
	recv_desc.color_format = NDIlib_recv_color_format_BGRX_BGRA;
	recv_desc.bandwidth = NDIlib_recv_bandwidth_highest;
	NDIlib_recv_instance_t recv = NDIlib_recv_create_v3(&recv_desc);
	if (!recv) { printf("could not create the receiver\n"); return 1; }

	const auto start = std::chrono::steady_clock::now();
	auto elapsed_min = [&] {
		return std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count() / 60.0;
	};

	int in_window = 0, total = 0, silent_minutes = 0;
	double next_report = 1.0;
	while (elapsed_min() < minutes) {
		NDIlib_video_frame_v2_t video;
		if (NDIlib_recv_capture_v2(recv, &video, nullptr, nullptr, 200) == NDIlib_frame_type_video) {
			in_window++;
			total++;
			NDIlib_recv_free_video_v2(recv, &video);
		}
		if (elapsed_min() >= next_report) {
			printf("[%5.1f min] %4d frames this minute, %6d total%s\n",
			       elapsed_min(), in_window, total, in_window == 0 ? "   <-- NOTHING ARRIVING" : "");
			fflush(stdout);
			if (in_window == 0) {
				if (++silent_minutes >= 3) {
					printf("[%5.1f min] delivery has been dead for 3 minutes; stopping\n", elapsed_min());
					fflush(stdout);
					break;
				}
			} else {
				silent_minutes = 0;
			}
			in_window = 0;
			next_report += 1.0;
		}
	}

	printf("finished: %d frames over %.1f min\n", total, elapsed_min());
	NDIlib_recv_destroy(recv);
	NDIlib_find_destroy(finder);
	NDIlib_destroy();
	return 0;
}
