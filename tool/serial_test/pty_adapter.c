#include "libserialport_internal.h"

enum sp_return sp_get_port_by_name(const char *name, struct sp_port **out) {
    struct sp_port *port = calloc(1, sizeof(*port));
    if (!port) return SP_ERR_MEM;
    port->name = strdup(name);
    port->fd = -1;
    *out = port;
    return SP_OK;
}

enum sp_return sp_open(struct sp_port *port, enum sp_mode mode) {
    (void)mode;
    port->fd = open(port->name, O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (port->fd < 0) return SP_ERR_FAIL;
    struct termios settings;
    if (tcgetattr(port->fd, &settings) < 0) return SP_ERR_FAIL;
    cfmakeraw(&settings);
    return tcsetattr(port->fd, TCSANOW, &settings) < 0 ? SP_ERR_FAIL : SP_OK;
}

enum sp_return sp_get_config(struct sp_port *port, struct sp_port_config *config) {
    (void)port;
    config->baudrate = 115200;
    config->bits = 8;
    config->parity = SP_PARITY_NONE;
    config->stopbits = 1;
    return SP_OK;
}

enum sp_return sp_set_config(struct sp_port *port, const struct sp_port_config *config) {
    (void)port;
    (void)config;
    return SP_OK;
}
