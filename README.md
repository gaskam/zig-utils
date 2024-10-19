# zig-utils
Some random code I made in order to improve my coding experience in zig.

## LineReader
A set made to help parse input line per line. Note that the user is responsible for freeing the result of the reads. Note that memory may leak if the input causes error(for instance if a string is provided when an integer is expected)