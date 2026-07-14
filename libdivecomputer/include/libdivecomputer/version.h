/*
 * libdivecomputer
 *
 * This file is derived from version.h.in for standalone builds where
 * autotools has not generated the header.
 */

#ifndef DC_VERSION_H
#define DC_VERSION_H

#ifdef __cplusplus
extern "C" {
#endif /* __cplusplus */

/* Project version */
#define DC_VERSION "0.9.0-74-g8e564eb"
#define DC_VERSION_MAJOR 0
#define DC_VERSION_MINOR 9
#define DC_VERSION_MICRO 0

#define DC_VERSION_CHECK(major,minor,micro) \
	(DC_VERSION_MAJOR > (major) || \
	(DC_VERSION_MAJOR == (major) && DC_VERSION_MINOR > (minor)) || \
	(DC_VERSION_MAJOR == (major) && DC_VERSION_MINOR == (minor) && \
		DC_VERSION_MICRO >= (micro)))

typedef struct dc_version_t {
	unsigned int major;
	unsigned int minor;
	unsigned int micro;
} dc_version_t;

const char *
dc_version (dc_version_t *version);

int
dc_version_check (unsigned int major, unsigned int minor, unsigned int micro);

#ifdef __cplusplus
}
#endif /* __cplusplus */

#endif /* DC_VERSION_H */

