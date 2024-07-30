/*
 * libdivecomputer
 *
 * Copyright (C) 2014 Linus Torvalds
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
 * MA 02110-1301 USA
 */

#ifndef SUUNTO_EONSTEEL_H
#define SUUNTO_EONSTEEL_H

#include <libdivecomputer/context.h>
#include <libdivecomputer/iostream.h>
#include <libdivecomputer/device.h>
#include <libdivecomputer/parser.h>
#include "context-private.h"
#include "device-private.h"
#include "array.h"
#include "platform.h"
#include "checksum.h"
#include "hdlc.h"

#ifdef __cplusplus
extern "C" {
#endif /* __cplusplus */

dc_status_t
suunto_eonsteel_device_open(dc_device_t **device, dc_context_t *context, dc_iostream_t *iostream, unsigned int model);

dc_status_t
suunto_eonsteel_parser_create(dc_parser_t **parser, dc_context_t *context, unsigned int model);

// New wrapper function for sending commands
dc_status_t
suunto_eonsteel_send_command(dc_device_t *device, unsigned short cmd, const unsigned char data[], unsigned int size);

#ifdef __cplusplus
}
#endif /* __cplusplus */
#endif /* SUUNTO_EONSTEEL_H */
