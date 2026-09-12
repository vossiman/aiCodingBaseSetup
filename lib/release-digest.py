#!/usr/bin/env python3
"""Hash a release using the existing NUL-delimited receipt format.

One sort process preserves the caller's GNU sort locale semantics. Files stream
through hashlib rather than spawning stat/sha256sum/awk processes per entry.
Directory and file descriptors never follow symlinks; any traversal/read error
fails the complete digest, without printing paths or file contents.
"""
import hashlib
import os
import stat
import subprocess
import sys


def digest(root):
    root = os.fsencode(root)
    records = {}
    path_prefix = root if root.endswith(b"/") else root + b"/"

    def walk(directory, prefix):
        with os.scandir(directory) as entries:
            for entry in entries:
                name = os.fsencode(entry.name)
                relative = prefix + name
                full_path = path_prefix + relative
                # Retain find's spelling and the shell's prefix removal even
                # for legacy callers that supplied a trailing slash.
                recorded_path = (full_path[len(root) + 1:]
                                 if full_path.startswith(root + b"/") else full_path)
                if recorded_path == b".aicoding-release-integrity":
                    continue
                metadata = os.stat(name, dir_fd=directory, follow_symlinks=False)
                mode = format(stat.S_IMODE(metadata.st_mode), "o").encode()
                value = b""
                if stat.S_ISLNK(metadata.st_mode):
                    kind = b"link"
                    # Shell command substitution removed trailing newlines.
                    value = os.readlink(name, dir_fd=directory).rstrip(b"\n")
                elif stat.S_ISREG(metadata.st_mode):
                    kind = b"file"
                    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                                 dir_fd=directory)
                    with os.fdopen(fd, "rb") as stream:
                        opened = os.fstat(stream.fileno())
                        if (not stat.S_ISREG(opened.st_mode)
                                or (opened.st_dev, opened.st_ino, opened.st_mode)
                                != (metadata.st_dev, metadata.st_ino, metadata.st_mode)):
                            raise OSError("release changed while hashing")
                        content = hashlib.sha256()
                        while chunk := stream.read(1024 * 1024):
                            content.update(chunk)
                        value = content.hexdigest().encode()
                    # GNU sha256sum prefixes its output with a backslash when
                    # escaping a filename. The old awk kept that prefix.
                    if b"\n" in full_path or b"\\" in full_path:
                        value = b"\\" + value
                elif stat.S_ISDIR(metadata.st_mode):
                    kind = b"directory"
                    child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                    dir_fd=directory)
                    try:
                        opened = os.fstat(child)
                        if (opened.st_dev, opened.st_ino, opened.st_mode) != (
                                metadata.st_dev, metadata.st_ino, metadata.st_mode):
                            raise OSError("release changed while traversing")
                        walk(child, relative + b"/")
                    finally:
                        os.close(child)
                else:
                    raise OSError("unsupported release entry")
                records[full_path] = b"\0".join(
                    (recorded_path, kind, mode, value)) + b"\0"

    directory = os.open(root.rstrip(b"/") or b"/",
                        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        walk(directory, b"")
    finally:
        os.close(directory)
    inventory = b"\0".join(records) + (b"\0" if records else b"")
    ordered = subprocess.run(["sort", "-z"], input=inventory, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, check=True).stdout
    result = hashlib.sha256()
    for path in ordered.split(b"\0")[:-1]:
        result.update(records[path])
    return result.hexdigest()


if __name__ == "__main__":
    try:
        print(digest(sys.argv[1]))
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        sys.exit(1)
