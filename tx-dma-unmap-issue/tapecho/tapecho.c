/*
 * Open a tap device and echo packets.
 *
 * It uses io_uring so asynchronous IO is used.
 */
#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>

#include <liburing.h>
#include <linux/if.h>
#include <linux/if_tun.h>
#include <sys/ioctl.h>

#define DEVNAME "tapecho"
#define MAX_MESSAGE_LEN 2048

/* Open TAP device. */
int tap_open(char *dev) {
  struct ifreq ifr;
  int fd, ret;
  char *clonedev = "/dev/net/tun";

  fd = open(clonedev, O_RDWR);
  if (fd < 0) {
    return fd;
  }

  memset(&ifr, 0, sizeof(ifr));
  strncpy(ifr.ifr_name, dev, IFNAMSIZ);
  ifr.ifr_flags = IFF_TAP | IFF_NO_PI;

  ret = ioctl(fd, TUNSETIFF, (void *)&ifr);
  if (ret < 0) {
    close(fd);
    return ret;
  }

  return fd;
}

/* Set device with given name up. */
int if_up(char *dev) {
  int sockfd, ret;
  struct ifreq ifr;

  sockfd = socket(AF_INET, SOCK_DGRAM, 0);
  if (sockfd < 0) {
    return sockfd;
  }

  memset(&ifr, 0, sizeof(ifr));
  strncpy(ifr.ifr_name, dev, IFNAMSIZ);
  ifr.ifr_flags |= IFF_UP;

  ret = ioctl(sockfd, SIOCSIFFLAGS, (void *)&ifr);
  close(sockfd);

  return ret;
}

/*
 * Set up TAP device with fixed name DEVNAME and echo any packet that is
 * received on the interface. Packets must not be longer than MAX_MESSAGE_LEN.
 */
int main(int argc, char *argv[]) {
  struct io_uring ring;
  struct io_uring_sqe *sqe;
  struct io_uring_cqe *cqe;
  int fd, last_result, read_pkt;
  char *dev = DEVNAME;
  char buf[MAX_MESSAGE_LEN] = {0};

  fd = tap_open(dev);
  if (fd < 0) {
    perror("open interface");
    exit(1);
  }

  if (if_up(dev) < 0) {
    perror("set interface up");
    exit(1);
  }

  if (io_uring_queue_init(1, &ring, 0) < 0) {
    perror("io_uring_init");
    exit(1);
  }

  /* Alternate between reading a packet and writing it back. */
  read_pkt = 1;
  while (1) {
    sqe = io_uring_get_sqe(&ring);
    assert(sqe);

    if (read_pkt) {
      io_uring_prep_read(sqe, fd, buf, sizeof(buf), 0);
      /* Write the read packet in the next iteration. */
      read_pkt = 0;
    } else {
      /* Write only the size of the packet that was read. */
      io_uring_prep_write(sqe, fd, buf, last_result, 0);
      /* Read a new packet in the next iteration. */
      read_pkt = 1;
    }

    if (io_uring_submit(&ring) < 0) {
      perror("submit");
      exit(1);
    }

    if (io_uring_wait_cqe(&ring, &cqe) < 0) {
      perror("wait completion");
      exit(1);
    }
    assert(cqe);

    last_result = cqe->res;
    assert(last_result);

    io_uring_cqe_seen(&ring, cqe);
  }
}
