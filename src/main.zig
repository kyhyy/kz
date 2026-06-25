//*** includes ***/
const std = @import("std");
const heap = @import("std").heap;
const mem = @import("std").mem;
const Io = @import("std").Io;

//*** defines ***//
fn CTRL_KEY(comptime k: u8) u8 {
    return k & 0x1f;
}

const kz_version = "0.0.1";
const KZ_TAB_STOP = 8;
const KZ_QUIT_TIMES = 3;
const HL_HIGHLIGHT_NUMBERS: u8 = 1 << 0;
const HL_HIGHLIGHT_STRINGS: u8 = 1 << 1;

const editorKey = enum(u16) { BACKSPACE = 0x7f, ARROW_LEFT = 0x1002, ARROW_RIGHT = 0x1003, ARROW_UP = 0x1000, ARROW_DOWN = 0x1001, HOME_KEY = 0x1004, END_KEY = 0x1005, PAGE_UP = 0x1006, PAGE_DOWN = 0x1007, DEL_KEY = 0x1008 };

const editorHighlight = enum(u8) {
    HL_NORMAL = 0,
    HL_COMMENT,
    HL_MLCOMMENT,
    HL_KEYWORD1,
    HL_KEYWORD2,
    HL_STRING,
    HL_NUMBER,
    HL_MATCH,
};

const EditorSyntax = struct {
    filetype: []const u8,
    filematch: []const []const u8,
    keywords: ?[]const []const u8,
    singleline_comment_start: ?[]const u8,
    multiline_comment_start: ?[]const u8,
    multiline_comment_end: ?[]const u8,
    flags: u8,
};

//*** data ***//
var io: Io = undefined;
var fnPressed: bool = false; // Global FN flag
var quit_times: u8 = KZ_QUIT_TIMES; // Global quit times counter

const UNDO_MAX = 1024;
const UndoKind = enum { insert_char, delete_char, delete_newline, insert_newline };
const UndoEntry = struct { kind: UndoKind, cx: u16, cy: u16, c: u8, new_group: bool = false };
var undo_stack: [UNDO_MAX]UndoEntry = undefined;
var undo_len: usize = 0;
var redo_stack: [UNDO_MAX]UndoEntry = undefined;
var redo_len: usize = 0;
var is_undoing: bool = false;

const Erow = struct {
    idx: usize, // Row index in the file
    size: usize, // Raw string size
    chars: []u8, // Raw string
    rsize: usize, // Rendered string size
    render: []u8, // Rendered string (with expanded tabs)
    hl: []u8, // Syntax highlight types for each character
    hl_open_comment: bool, // Whether the row is part of an open multiline comment
};

const EditorConfig = struct {
    cx: u16,
    cy: u16,
    rx: u16,
    rowoff: u16,
    coloff: u16,

    screenrows: u16,
    screencols: u16,

    numrows: u16,
    rows: []Erow,
    filename: ?[]const u8,
    dirty: u16,

    statusmsg: [80]u8,
    statusmsg_time: i128,

    syntax: ?*const EditorSyntax,

    orig_termios: std.posix.termios,
};

var E = EditorConfig{
    .cx = undefined,
    .cy = undefined,
    .rx = undefined,
    .rowoff = undefined,
    .coloff = undefined,

    .screenrows = undefined,
    .screencols = undefined,

    .numrows = 0,
    .rows = undefined,
    .filename = null,
    .dirty = 0,

    .statusmsg = undefined,
    .statusmsg_time = 0,

    .syntax = null,

    .orig_termios = undefined,
};

const KeyAction = enum {
    Quit,
    NoOp,
};

//*** filetypes ***//
const C_HL_extensions = [_][]const u8{ ".c", ".h", ".cpp" };
const C_HL_keywords = [_][]const u8{
    "switch",  "if",   "while", "for",  "break", "continue", "return", "else",    "struct", "union", "typedef",
    "static",  "enum", "class", "case", "int|",  "long|",    "float|", "double|", "char|",  "void|", "unsigned|",
    "signed|",
};

const ZIG_HL_extensions = [_][]const u8{".zig"};
const ZIG_HL_keywords = [_][]const u8{
    "if",       "else",        "while",  "for",      "switch",    "break", "continue",  "return",
    "fn",       "pub",         "const",  "var",      "comptime",  "try",   "catch",     "defer",
    "errdefer", "unreachable", "struct", "union",    "enum",      "error", "test",      "inline",
    "extern",   "export",      "orelse", "and",      "or",        "null",  "undefined", "bool|",
    "u8|",      "u16|",        "u32|",   "u64|",     "u128|",     "i8|",   "i16|",      "i32|",
    "i64|",     "i128|",       "f16|",   "f32|",     "f64|",      "f128|", "usize|",    "isize|",
    "void|",    "noreturn|",   "type|",  "anytype|", "anyerror|",
};

const NIM_HL_extensions = [_][]const u8{ ".nim", ".nims" };
const NIM_HL_keywords = [_][]const u8{
    "if",       "elif",     "else",   "when",     "while",    "for",     "case",    "of",
    "break",    "continue", "return", "yield",    "try",      "except",  "finally", "raise",
    "proc",     "func",     "method", "iterator", "template", "macro",   "type",    "var",
    "let",      "const",    "import", "export",   "include",  "from",    "block",   "object",
    "enum",     "and",      "or",     "not",      "in",       "notin",   "is",      "isnot",
    "nil",      "true",     "false",  "discard",  "do",       "int|",    "int8|",   "int16|",
    "int32|",   "int64|",   "uint|",  "uint8|",   "uint16|",  "uint32|", "uint64|", "float|",
    "float32|", "float64|", "bool|",  "char|",    "string|",  "seq|",    "void|",   "auto|",
};

const HLDB = [_]EditorSyntax{
    .{
        .filetype = "c",
        .filematch = &C_HL_extensions,
        .keywords = &C_HL_keywords,
        .singleline_comment_start = "//",
        .multiline_comment_start = "/*",
        .multiline_comment_end = "*/",
        .flags = HL_HIGHLIGHT_NUMBERS | HL_HIGHLIGHT_STRINGS,
    },
    .{
        .filetype = "zig",
        .filematch = &ZIG_HL_extensions,
        .keywords = &ZIG_HL_keywords,
        .singleline_comment_start = "//",
        .multiline_comment_start = null,
        .multiline_comment_end = null,
        .flags = HL_HIGHLIGHT_NUMBERS | HL_HIGHLIGHT_STRINGS,
    },
    .{
        .filetype = "nim",
        .filematch = &NIM_HL_extensions,
        .keywords = &NIM_HL_keywords,
        .singleline_comment_start = "#",
        .multiline_comment_start = "#[",
        .multiline_comment_end = "]#",
        .flags = HL_HIGHLIGHT_NUMBERS | HL_HIGHLIGHT_STRINGS,
    },
};

//*** terminal ***//
// Function to restore the original terminal settings
export fn disableRawMode() void {
    std.posix.tcsetattr(Io.File.stdin().handle, .FLUSH, E.orig_termios) catch {
        std.debug.print("Error: Failed to restore terminal settings\n", .{});
        std.process.exit(1);
    };
}

fn die(msg: []const u8) noreturn {
    // Create buffer for stdout
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    stdout.writeAll("\x1b[2J") catch {};
    stdout.writeAll("\x1b[H") catch {};
    stdout.flush() catch {};

    std.debug.print("Error: {s}\n", .{msg});
    std.process.exit(1);
}

// Function to enable raw mode in the terminal
fn enableRawMode() !void {
    const stdin = Io.File.stdin().handle;

    E.orig_termios = std.posix.tcgetattr(stdin) catch {
        std.debug.print("Error: Could not get terminal attributes\n", .{});
        return error.TerminalError;
    };

    var raw = E.orig_termios;

    // Terminal mode flags:
    raw.lflag.ECHO = false; // Don't echo input characters
    raw.lflag.ICANON = false; // Read input byte-by-byte instead of line-by-line
    raw.lflag.ISIG = false; // Disable Ctrl-C and Ctrl-Z signals
    raw.iflag.IXON = false; // Disable Ctrl-S and Ctrl-Q signals
    raw.lflag.IEXTEN = false; // Disable Ctrl-V
    raw.iflag.ICRNL = false; // Fix Ctrl-M
    raw.oflag.OPOST = false; // Disable output processing
    raw.iflag.BRKINT = false; // Disable break processing
    raw.iflag.INPCK = false; // Disable parity checking
    raw.iflag.ISTRIP = false; // Disable stripping of 8th bit
    raw.cflag.CSIZE = .CS8; // Use 8-bit characters

    // Set read timeouts
    const VMIN = 5; // Minimum number of bytes before read returns
    const VTIME = 6; // Time to wait for input (tenths of seconds)
    raw.cc[VMIN] = 0; // Return immediately when any bytes are available
    raw.cc[VTIME] = 1; // Wait up to 0.1 seconds for input

    std.posix.tcsetattr(stdin, .FLUSH, raw) catch {
        std.debug.print("Error: Could not set terminal attributes\n", .{});
        return error.TerminalError;
    };
}

fn editorReadKey() !u16 {
    var buf: [1]u8 = undefined;
    const stdin_file = Io.File.stdin();
    var stdin_buffer: [1024]u8 = undefined;
    var stdin_reader = stdin_file.reader(io, &stdin_buffer);
    const stdin = &stdin_reader.interface;

    while (true) {
        const n = try stdin.*.readSliceShort(buf[0..]);
        if (n == 1) break;
    }

    // Read escape sequence
    if (buf[0] == '\x1b') {
        var seq: [3]u8 = undefined;

        // Read first character of sequence
        const seq1 = try stdin.*.readSliceShort(seq[0..1]);
        if (seq1 != 1) return '\x1b';

        if (seq[0] == '[') {
            // Read second character
            const seq2 = try stdin.*.readSliceShort(seq[1..2]);
            if (seq2 != 1) return '\x1b';

            if (seq[1] >= '0' and seq[1] <= '9') {
                // Read third character for extended sequences
                const seq3 = try stdin.*.readSliceShort(seq[2..3]);
                if (seq3 != 1) return '\x1b';

                if (seq[2] == '~') {
                    // Handle Page Up/Down and Home/End keys
                    return switch (seq[1]) {
                        '1' => @intFromEnum(editorKey.HOME_KEY),
                        '3' => @intFromEnum(editorKey.DEL_KEY),
                        '4' => @intFromEnum(editorKey.END_KEY),
                        '5' => @intFromEnum(editorKey.PAGE_UP),
                        '6' => @intFromEnum(editorKey.PAGE_DOWN),
                        '7' => @intFromEnum(editorKey.HOME_KEY),
                        '8' => @intFromEnum(editorKey.END_KEY),
                        else => '\x1b',
                    };
                }
            } else {
                // Handle arrow keys
                return switch (seq[1]) {
                    'A' => @intFromEnum(editorKey.ARROW_UP),
                    'B' => @intFromEnum(editorKey.ARROW_DOWN),
                    'C' => @intFromEnum(editorKey.ARROW_RIGHT),
                    'D' => @intFromEnum(editorKey.ARROW_LEFT),
                    'H' => @intFromEnum(editorKey.HOME_KEY),
                    'F' => @intFromEnum(editorKey.END_KEY),
                    else => '\x1b',
                };
            }
        } else if (seq[0] == 'O') {
            const seq2 = try stdin.*.readSliceShort(seq[1..2]);
            if (seq2 != 1) return '\x1b';

            return switch (seq[1]) {
                'H' => @intFromEnum(editorKey.HOME_KEY),
                'F' => @intFromEnum(editorKey.END_KEY),
                else => '\x1b',
            };
        }
        return '\x1b';
    }
    return buf[0];
}

fn getWindowSize(rows: *u16, cols: *u16) !void {
    var ws: std.posix.winsize = undefined;
    const fd = std.posix.STDOUT_FILENO;

    if (std.posix.system.ioctl(fd, std.posix.T.IOCGWINSZ, @intFromPtr(&ws)) == -1 or ws.col == 0) {
        return error.TerminalSizeError;
    }

    rows.* = ws.row;
    cols.* = ws.col;
}

fn editorRowCxToRx(row: *const Erow, cx: u16) u16 {
    var rx: u16 = 0;
    var j: u16 = 0;
    while (j < cx) : (j += 1) {
        if (row.chars[j] == '\t') {
            rx += (KZ_TAB_STOP - 1) - (rx % KZ_TAB_STOP) + 1;
        } else {
            rx += 1;
        }
    }
    return rx;
}

fn editorRowRxToCx(row: *const Erow, rx: u16) u16 {
    var cur_rx: u16 = 0;
    var cx: u16 = 0;
    while (cx < row.size) : (cx += 1) {
        if (row.chars[cx] == '\t') {
            cur_rx += (KZ_TAB_STOP - 1) - (cur_rx % KZ_TAB_STOP) + 1;
        } else {
            cur_rx += 1;
        }
        if (cur_rx > rx) return cx;
    }
    return cx;
}

fn editorInsertRow(allocator: mem.Allocator, at: usize, s: []const u8) !void {
    if (at > E.numrows) return;

    E.rows = try allocator.realloc(E.rows, E.numrows + 1);

    if (at < E.numrows) {
        @memmove(E.rows[at + 1 .. E.numrows + 1], E.rows[at..E.numrows]);
        var j: usize = at + 1;
        while (j <= E.numrows) : (j += 1) {
            E.rows[j].idx += 1;
        }
    }

    E.rows[at] = .{
        .idx = at,
        .size = s.len,
        .chars = try allocator.alloc(u8, s.len + 1),
        .rsize = 0,
        .render = &[_]u8{},
        .hl = &[_]u8{},
        .hl_open_comment = false,
    };

    @memcpy(E.rows[at].chars[0..s.len], s);
    E.rows[at].chars[s.len] = 0;

    try editorUpdateRow(allocator, &E.rows[at]);

    E.numrows += 1;
    E.dirty += 1;
}

fn editorUpdateRow(allocator: mem.Allocator, row: *Erow) !void {
    var tabs: usize = 0;
    for (row.chars[0..row.size]) |c| {
        if (c == '\t') tabs += 1;
    }

    const extra_space_per_tab = KZ_TAB_STOP - 1;
    const new_size = row.size + (tabs * extra_space_per_tab) + 1;

    if (row.render.len > 0) {
        allocator.free(row.render);
    }

    row.render = try allocator.alloc(u8, new_size);

    var idx: usize = 0;
    for (row.chars[0..row.size]) |c| {
        if (c == '\t') {
            row.render[idx] = ' ';
            idx += 1;

            while (idx % KZ_TAB_STOP != 0) : (idx += 1) {
                row.render[idx] = ' ';
                idx += 1;
            }
        } else {
            row.render[idx] = c;
            idx += 1;
        }
    }

    row.render[row.size] = 0;
    row.rsize = row.size;

    try editorUpdateSyntax(allocator, row);
}

fn editorFreeRow(allocator: mem.Allocator, row: *Erow) void {
    allocator.free(row.chars);
    allocator.free(row.render);
    allocator.free(row.hl);
}

fn editorDelRow(allocator: mem.Allocator, at: usize) void {
    if (at >= E.numrows) return;

    editorFreeRow(allocator, &E.rows[at]);

    if (at + 1 < E.numrows) {
        @memmove(E.rows[at .. E.numrows - 1], E.rows[at + 1 .. E.numrows]);
    }

    var j: usize = at;
    while (j < E.numrows - 1) : (j += 1) {
        E.rows[j].idx -= 1;
    }

    E.numrows -= 1;
    E.dirty += 1;
}

fn editorRowInsertChar(allocator: mem.Allocator, row: *Erow, at: usize, c: u8) !void {
    var insert_at = at;
    if (insert_at > row.size) {
        insert_at = row.size;
    }

    // Reallocate to make room for one more character
    row.chars = try allocator.realloc(row.chars, row.size + 1);

    // Move characters after insertion point one position to the right
    if (insert_at < row.size) {
        @memmove(row.chars[insert_at + 1 .. row.size + 1], row.chars[insert_at..row.size]);
    }

    row.size += 1;
    row.chars[insert_at] = c;

    try editorUpdateRow(allocator, row);
    E.dirty += 1;
}

fn editorRowAppendString(allocator: mem.Allocator, row: *Erow, s: []const u8) !void {
    const old_size = row.size;

    row.chars = try allocator.realloc(row.chars, old_size + s.len + 1);

    @memcpy(row.chars[old_size .. old_size + s.len], s);

    row.size += s.len;
    row.chars[row.size] = 0;

    try editorUpdateRow(allocator, row);
    E.dirty += 1;
}

fn editorRowDelChar(allocator: mem.Allocator, row: *Erow, at: usize) !void {
    if (at >= row.size) return;

    // Move characters after deletion point one position to the left
    if (at < row.size - 1) {
        @memmove(row.chars[at .. row.size - 1], row.chars[at + 1 .. row.size]);
    }

    row.size -= 1;
    try editorUpdateRow(allocator, row);
    E.dirty += 1;
}

//*** syntax highlighting ***//
fn isSeparator(c: u8) bool {
    return std.ascii.isWhitespace(c) or c == 0 or std.mem.indexOfScalar(u8, ",.()+-/*=~%<>[];", c) != null;
}

fn editorUpdateSyntax(allocator: mem.Allocator, row: *Erow) !void {
    if (row.hl.len > 0) {
        allocator.free(row.hl);
    }
    row.hl = try allocator.alloc(u8, row.rsize);

    @memset(row.hl, @intFromEnum(editorHighlight.HL_NORMAL));

    if (E.syntax == null) return;

    const keywords = E.syntax.?.keywords;
    const scs = E.syntax.?.singleline_comment_start;
    const mcs = E.syntax.?.multiline_comment_start;
    const mce = E.syntax.?.multiline_comment_end;

    const scs_len = if (scs) |s| s.len else 0;
    const mcs_len = if (mcs) |s| s.len else 0;
    const mce_len = if (mce) |s| s.len else 0;

    var prev_sep: bool = true;
    var in_string: u8 = 0;
    var in_comment: bool = (row.idx > 0 and E.rows[row.idx - 1].hl_open_comment);

    var i: usize = 0;
    while (i < row.rsize) {
        const c = row.render[i];
        const prev_hl: u8 = if (i > 0) row.hl[i - 1] else @intFromEnum(editorHighlight.HL_NORMAL);

        if (scs_len > 0 and in_string == 0 and !in_comment) {
            if (i + scs_len <= row.rsize and std.mem.eql(u8, row.render[i .. i + scs_len], scs.?)) {
                @memset(row.hl[i..row.rsize], @intFromEnum(editorHighlight.HL_COMMENT));
                break;
            }
        }

        if (mcs_len > 0 and mce_len > 0 and in_string == 0) {
            if (in_comment) {
                row.hl[i] = @intFromEnum(editorHighlight.HL_MLCOMMENT);
                if (i + mce_len <= row.rsize and std.mem.eql(u8, row.render[i .. i + mce_len], mce.?)) {
                    @memset(row.hl[i .. i + mce_len], @intFromEnum(editorHighlight.HL_MLCOMMENT));
                    i += mce_len;
                    in_comment = false;
                    prev_sep = true;
                    continue;
                } else {
                    i += 1;
                    continue;
                }
            } else if (i + mcs_len <= row.rsize and std.mem.eql(u8, row.render[i .. i + mcs_len], mcs.?)) {
                @memset(row.hl[i .. i + mcs_len], @intFromEnum(editorHighlight.HL_MLCOMMENT));
                i += mcs_len;
                in_comment = true;
                continue;
            }
        }

        if (E.syntax.?.flags & HL_HIGHLIGHT_STRINGS != 0) {
            if (in_string != 0) {
                row.hl[i] = @intFromEnum(editorHighlight.HL_STRING);
                if (c == '\\' and i + 1 < row.rsize) {
                    row.hl[i + 1] = @intFromEnum(editorHighlight.HL_STRING);
                    i += 2;
                    continue;
                }
                if (c == in_string) in_string = 0;
                i += 1;
                prev_sep = true;
                continue;
            } else {
                if (c == '"' or c == '\'') {
                    in_string = c;
                    row.hl[i] = @intFromEnum(editorHighlight.HL_STRING);
                    i += 1;
                    continue;
                }
            }
        }

        if (E.syntax.?.flags & HL_HIGHLIGHT_NUMBERS != 0) {
            if ((std.ascii.isDigit(c) and (prev_sep or prev_hl == @intFromEnum(editorHighlight.HL_NUMBER))) or
                (c == '.' and prev_hl == @intFromEnum(editorHighlight.HL_NUMBER)))
            {
                row.hl[i] = @intFromEnum(editorHighlight.HL_NUMBER);
                i += 1;
                prev_sep = false;
                continue;
            }
        }

        if (prev_sep) {
            if (keywords) |kws| {
                var j: usize = 0;
                while (j < kws.len) : (j += 1) {
                    const keyword = kws[j];
                    var klen = keyword.len;
                    const kw2 = keyword[klen - 1] == '|';
                    if (kw2) klen -= 1;

                    if (i + klen <= row.rsize and
                        std.mem.eql(u8, row.render[i .. i + klen], keyword[0..klen]) and
                        isSeparator(row.render[i + klen]))
                    {
                        @memset(row.hl[i .. i + klen], @intFromEnum(if (kw2) editorHighlight.HL_KEYWORD2 else editorHighlight.HL_KEYWORD1));
                        i += klen;
                        break;
                    }
                }
                if (j < kws.len) {
                    prev_sep = false;
                    continue;
                }
            }
        }

        prev_sep = isSeparator(c);
        i += 1;
    }

    const changed = (row.hl_open_comment != in_comment);
    row.hl_open_comment = in_comment;
    if (changed and row.idx + 1 < E.numrows) {
        editorUpdateSyntax(allocator, &E.rows[row.idx + 1]) catch {};
    }
}

fn editorSyntaxToColor(hl: u8) u8 {
    return switch (@as(editorHighlight, @enumFromInt(hl))) {
        .HL_COMMENT, .HL_MLCOMMENT => 36, // Cyan
        .HL_KEYWORD1 => 33, // Yellow
        .HL_KEYWORD2 => 32, // Green
        .HL_STRING => 35, // Magenta
        .HL_NUMBER => 31, // Red
        .HL_MATCH => 34, // Blue
        else => 37, // White (default)
    };
}

fn editorSelectSyntaxHighlight(allocator: mem.Allocator) void {
    E.syntax = null;
    if (E.filename == null) return;

    const filename = E.filename.?;
    const ext = blk: {
        var i = filename.len;
        while (i > 0) : (i -= 1) {
            if (filename[i - 1] == '.') {
                break :blk filename[i - 1 ..];
            }
        }
        break :blk null;
    };

    for (&HLDB) |*s| {
        for (s.filematch) |pattern| {
            const is_ext = pattern[0] == '.';
            if ((is_ext and ext != null and std.mem.eql(u8, ext.?, pattern)) or
                (!is_ext and std.mem.indexOf(u8, filename, pattern) != null))
            {
                E.syntax = s;

                var filerow: usize = 0;
                while (filerow < E.numrows) : (filerow += 1) {
                    editorUpdateSyntax(allocator, &E.rows[filerow]) catch {};
                }

                return;
            }
        }
    }
}

//*** editor operations ***//
fn pushUndo(entry_in: UndoEntry) void {
    if (is_undoing) return;
    redo_len = 0;
    if (undo_len >= UNDO_MAX) return;
    var entry = entry_in;
    entry.new_group = if (undo_len == 0) true else blk: {
        const prev = undo_stack[undo_len - 1];
        if (prev.kind != entry.kind) break :blk true;
        break :blk switch (entry.kind) {
            .insert_char => entry.cy != prev.cy or entry.cx != prev.cx + 1 or isSeparator(entry.c) or isSeparator(prev.c),
            .delete_char => entry.cy != prev.cy or entry.cx != prev.cx - 1 or isSeparator(entry.c) or isSeparator(prev.c),
            else => true,
        };
    };
    undo_stack[undo_len] = entry;
    undo_len += 1;
}

fn editorInsertChar(allocator: mem.Allocator, c: u8) !void {
    pushUndo(.{ .kind = .insert_char, .cx = E.cx, .cy = E.cy, .c = c });
    if (E.cy == E.numrows) {
        try editorInsertRow(allocator, E.numrows, "");
    }
    try editorRowInsertChar(
        allocator,
        &E.rows[E.cy],
        @intCast(E.cx),
        c,
    );
    E.cx += 1;
}

fn editorDelChar(allocator: mem.Allocator) !void {
    if (E.cy == E.numrows) return;
    if (E.cx == 0 and E.cy == 0) return;

    const row = &E.rows[E.cy];
    if (E.cx > 0) {
        pushUndo(.{ .kind = .delete_char, .cx = E.cx, .cy = E.cy, .c = row.chars[E.cx - 1] });
        try editorRowDelChar(allocator, row, E.cx - 1);
        E.cx -= 1;
    } else {
        pushUndo(.{ .kind = .delete_newline, .cx = @intCast(E.rows[E.cy - 1].size), .cy = E.cy - 1, .c = 0 });
        E.cx = @intCast(E.rows[E.cy - 1].size);
        try editorRowAppendString(allocator, &E.rows[E.cy - 1], row.chars[0..row.size]);
        editorDelRow(allocator, E.cy);
        E.cy -= 1;
    }
}

fn editorUndo(allocator: mem.Allocator) !void {
    if (undo_len == 0) {
        editorSetStatusMessage("Nothing to undo", .{});
        return;
    }
    is_undoing = true;
    defer is_undoing = false;
    while (undo_len > 0) {
        undo_len -= 1;
        const entry = undo_stack[undo_len];
        switch (entry.kind) {
            .insert_char => {
                E.cx = entry.cx + 1;
                E.cy = entry.cy;
                try editorDelChar(allocator);
            },
            .delete_char => {
                E.cx = entry.cx - 1;
                E.cy = entry.cy;
                try editorInsertChar(allocator, entry.c);
            },
            .delete_newline => {
                E.cx = entry.cx;
                E.cy = entry.cy;
                try editorInsertNewline(allocator);
            },
            .insert_newline => {
                var i: usize = 0;
                while (i < entry.c and entry.cy + 1 < E.numrows) : (i += 1)
                    try editorRowDelChar(allocator, &E.rows[entry.cy + 1], 0);
                E.cx = 0;
                E.cy = entry.cy + 1;
                try editorDelChar(allocator);
            },
        }
        if (redo_len < UNDO_MAX) {
            redo_stack[redo_len] = entry;
            redo_len += 1;
        }
        if (entry.new_group) break;
    }
}

fn editorRedo(allocator: mem.Allocator) !void {
    if (redo_len == 0) {
        editorSetStatusMessage("Nothing to redo", .{});
        return;
    }
    is_undoing = true;
    defer is_undoing = false;
    while (redo_len > 0) {
        redo_len -= 1;
        const entry = redo_stack[redo_len];
        switch (entry.kind) {
            .insert_char => {
                E.cx = entry.cx;
                E.cy = entry.cy;
                try editorInsertChar(allocator, entry.c);
            },
            .delete_char => {
                E.cx = entry.cx;
                E.cy = entry.cy;
                try editorDelChar(allocator);
            },
            .delete_newline => {
                E.cx = 0;
                E.cy = entry.cy + 1;
                try editorDelChar(allocator);
            },
            .insert_newline => {
                E.cx = entry.cx;
                E.cy = entry.cy;
                try editorInsertNewline(allocator);
            },
        }
        if (undo_len < UNDO_MAX) {
            undo_stack[undo_len] = entry;
            undo_len += 1;
        }
        if (redo_len == 0 or redo_stack[redo_len - 1].new_group) break;
    }
}

fn editorInsertNewline(allocator: mem.Allocator) !void {
    var indent_len: usize = 0;
    if (E.cy < E.numrows and E.cx > 0) {
        const row = &E.rows[E.cy];
        while (indent_len < E.cx and (row.chars[indent_len] == ' ' or row.chars[indent_len] == '\t')) : (indent_len += 1) {}
    }
    pushUndo(.{ .kind = .insert_newline, .cx = E.cx, .cy = E.cy, .c = @intCast(indent_len) });
    if (E.cx == 0) {
        try editorInsertRow(allocator, E.cy, "");
    } else {
        const row = &E.rows[E.cy];
        const rest = row.chars[E.cx..row.size];
        const new_content = try allocator.alloc(u8, indent_len + rest.len);
        defer allocator.free(new_content);
        @memcpy(new_content[0..indent_len], row.chars[0..indent_len]);
        @memcpy(new_content[indent_len..], rest);
        try editorInsertRow(allocator, E.cy + 1, new_content);

        const row2 = &E.rows[E.cy];
        row2.size = E.cx;
        row2.chars[row2.size] = 0;
        try editorUpdateRow(allocator, row2);
    }
    E.cy += 1;
    E.cx = @intCast(indent_len);
}

//*** file i/o ***//
fn editorRowsToString(allocator: mem.Allocator) ![]u8 {
    var total_size: usize = 0;
    var i: usize = 0;
    while (i < E.numrows) : (i += 1) {
        total_size += E.rows[i].size + 1; // +1 for newline
    }

    const buf = try allocator.alloc(u8, total_size);
    var p: usize = 0;

    i = 0;
    while (i < E.numrows) : (i += 1) {
        @memcpy(buf[p .. p + E.rows[i].size], E.rows[i].chars[0..E.rows[i].size]);
        p += E.rows[i].size;
        buf[p] = '\n';
        p += 1;
    }

    return buf;
}

fn editorOpen(allocator: mem.Allocator, filename: []const u8) !void {
    if (E.filename) |old_filename| {
        allocator.free(old_filename);
    }

    E.filename = try allocator.dupe(u8, filename);
    editorSelectSyntaxHighlight(allocator);

    const file = Io.Dir.cwd().openFile(io, filename, .{ .mode = .read_only }) catch |err| {
        if (err == error.FileNotFound) {
            return;
        }
        return err;
    };
    defer file.close(io);

    const file_size = try file.length(io);
    const file_contents = try allocator.alloc(u8, file_size);
    defer allocator.free(file_contents);

    var file_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &file_buffer);
    const reader = &file_reader.interface;

    try reader.*.readSliceAll(file_contents);

    var line_start: usize = 0;
    var line_end: usize = 0;

    while (line_end < file_size) {
        while (line_end < file_size and
            file_contents[line_end] != '\n' and
            file_contents[line_end] != '\r')
        {
            line_end += 1;
        }

        try editorInsertRow(allocator, E.numrows, file_contents[line_start..line_end]);

        if (line_end < file_size and file_contents[line_end] == '\r') line_end += 1;
        if (line_end < file_size and file_contents[line_end] == '\n') line_end += 1;
        line_start = line_end;
    }
    E.dirty = 0;
}

fn editorSave(allocator: mem.Allocator) !void {
    if (E.filename == null) {
        E.filename = try editorPrompt(allocator, "Save as: ", null);
        if (E.filename == null) {
            editorSetStatusMessage("Save aborted", .{});
            return;
        }
        editorSelectSyntaxHighlight(allocator);
    }

    // Convert rows to a single buffer
    const buf = try editorRowsToString(allocator);
    defer allocator.free(buf);

    // Unwrap the optional filename
    const filename = E.filename.?; // Safe because we checked for null in first line

    // Open file for read/write, create if it doesn't exist
    if (Io.Dir.cwd().createFile(io, filename, .{ .truncate = true })) |file| {
        defer file.close(io);
        // Try to write
        if (file.writeStreamingAll(io, buf)) |_| {
            E.dirty = 0;
            editorSetStatusMessage("{d} bytes written to disk", .{buf.len});
            return;
        } else |_| {
            // Write failed, fall through to error message
        }
    } else |_| {
        // File creation failed, fall through to error message
    }

    // Single error message - reached if ANY operation failed
    editorSetStatusMessage("Can't save! I/O error", .{});
}

//*** find ***//
fn editorFindCallback(allocator: mem.Allocator, query: []const u8, key: u16) void {
    const search_state = struct {
        var last_match: i32 = -1;
        var direction: i8 = 1;
        var saved_hl_line: usize = 0;
        var saved_hl: ?[]u8 = null;
    };

    if (search_state.saved_hl) |hl| {
        @memcpy(E.rows[search_state.saved_hl_line].hl, hl);
        allocator.free(hl);
        search_state.saved_hl = null;
    }

    if (key == '\r' or key == '\x1b') {
        search_state.last_match = -1;
        search_state.direction = 1;
        return;
    } else if (key == @intFromEnum(editorKey.ARROW_RIGHT) or key == @intFromEnum(editorKey.ARROW_DOWN)) {
        search_state.direction = 1;
    } else if (key == @intFromEnum(editorKey.ARROW_LEFT) or key == @intFromEnum(editorKey.ARROW_UP)) {
        search_state.direction = -1;
    } else {
        search_state.last_match = -1;
        search_state.direction = 1;
    }

    if (search_state.last_match == -1) search_state.direction = 1;
    var current = search_state.last_match;

    var i: usize = 0;
    while (i < E.numrows) : (i += 1) {
        current += search_state.direction;
        if (current == -1) {
            current = @as(i32, @intCast(E.numrows)) - 1;
        } else if (current == @as(i32, @intCast(E.numrows))) {
            current = 0;
        }

        const row = &E.rows[@intCast(current)];
        if (std.mem.indexOf(u8, row.render[0..row.rsize], query)) |match_index| {
            search_state.last_match = current;
            E.cy = @intCast(current);
            E.cx = editorRowRxToCx(row, @intCast(match_index));
            E.rowoff = E.numrows;

            search_state.saved_hl_line = @intCast(current);
            search_state.saved_hl = allocator.alloc(u8, row.rsize) catch null;
            if (search_state.saved_hl) |hl| {
                @memcpy(hl, row.hl);
            }

            @memset(row.hl[match_index .. match_index + query.len], @intFromEnum(editorHighlight.HL_MATCH));
            break;
        }
    }
}

fn editorFind(allocator: mem.Allocator) !void {
    const saved_cx = E.cx;
    const saved_cy = E.cy;
    const saved_coloff = E.coloff;
    const saved_rowoff = E.rowoff;

    const query = try editorPrompt(allocator, "(Use ESC/Arrows/Enter) Search: ", editorFindCallback);
    if (query) |q| {
        allocator.free(q);
    } else {
        E.cx = saved_cx;
        E.cy = saved_cy;
        E.coloff = saved_coloff;
        E.rowoff = saved_rowoff;
    }
}

//*** output ***//
fn lineNumWidth() usize {
    var n = if (E.numrows > 0) E.numrows else 1;
    var w: usize = 1;
    while (n >= 10) : (n /= 10) w += 1;
    return w + 1; // digits + trailing space
}

fn editorScroll() !void {
    E.rx = 0;
    if (E.cy < E.numrows) {
        E.rx = editorRowCxToRx(&E.rows[E.cy], E.cx);
    }

    if (E.cy < E.rowoff) {
        E.rowoff = E.cy;
    }
    if (E.cy >= E.rowoff + E.screenrows) {
        E.rowoff = E.cy - E.screenrows + 1;
    }
    if (E.rx < E.coloff) {
        E.coloff = E.rx;
    }
    const content_cols = E.screencols - @as(u16, @intCast(lineNumWidth()));
    if (E.rx >= E.coloff + content_cols) {
        E.coloff = E.rx - content_cols + 1;
    }
}

fn editorDrawStatusBar(list_writer: anytype) !void {
    try list_writer.writeAll("\x1b[7m"); // Invert colors
    var status: [80]u8 = undefined;
    var rstatus: [80]u8 = undefined;

    const status_slice = try std.fmt.bufPrint(&status, "{s} - {d} lines {s}", .{
        if (E.filename) |fname| fname else "[No Name]",
        E.numrows,
        if (E.dirty > 0) "modified" else "",
    });
    const rstatus_slice = try std.fmt.bufPrint(&rstatus, "{s} | {d}/{d}", .{
        if (E.syntax) |syn| syn.filetype else "no ft",
        E.cy + 1,
        E.numrows,
    });

    var len = status_slice.len;
    if (len > E.screencols) {
        len = E.screencols;
    }

    try list_writer.writeAll(status[0..len]);
    while (len < E.screencols) {
        if (E.screencols - len == rstatus_slice.len) {
            try list_writer.writeAll(rstatus_slice);
            break;
        } else {
            try list_writer.writeAll(" ");
            len += 1;
        }
    }
    try list_writer.writeAll("\x1b[m"); // Reset formatting
    try list_writer.writeAll("\r\n");
}

fn editorDrawMessageBar(list_writer: anytype) !void {
    try list_writer.writeAll("\x1b[K");

    var msg_len: usize = 0;
    while (msg_len < E.statusmsg.len and E.statusmsg[msg_len] != 0) {
        msg_len += 1;
    }
    if (msg_len > E.screencols) {
        msg_len = E.screencols;
    }
    if (msg_len > 0 and Io.Timestamp.now(io, .real).nanoseconds - E.statusmsg_time < 5 * std.time.ns_per_s) {
        try list_writer.writeAll(E.statusmsg[0..msg_len]);
    }
}

fn editorRefreshScreen(allocator: mem.Allocator) !void {
    try editorScroll();

    var initial_buf = std.ArrayList(u8).empty;
    var alloc_writer = std.Io.Writer.Allocating.fromArrayList(allocator, &initial_buf);
    defer alloc_writer.deinit();
    const list_writer = &alloc_writer.writer;

    try list_writer.writeAll("\x1b[?25l");
    try list_writer.writeAll("\x1b[H");

    try editorDrawRows(list_writer);
    try editorDrawStatusBar(list_writer);
    try editorDrawMessageBar(list_writer);

    try list_writer.print("\x1b[{d};{d}H", .{ (E.cy - E.rowoff) + 1, (E.rx - E.coloff) + 1 + lineNumWidth() });

    try list_writer.writeAll("\x1b[?25h");

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.writeAll(list_writer.buffer[0..list_writer.end]);
    try stdout.flush();
}

fn editorDrawRows(writer: anytype) !void {
    const lnw = lineNumWidth();
    const content_cols = E.screencols - @as(u16, @intCast(lnw));
    var y: usize = 0;
    while (y < E.screenrows) : (y += 1) {
        const filerow = y + E.rowoff;
        if (filerow >= E.numrows) {
            if (E.numrows == 0 and y == E.screenrows / 3) {
                var welcome: [80]u8 = undefined;
                const welcome_msg = try std.fmt.bufPrint(&welcome, "kz editor -- version {s}", .{kz_version});

                const display_len = @min(welcome_msg.len, content_cols);
                const padding = (content_cols - display_len) / 2;

                var g: usize = 0;
                while (g < lnw) : (g += 1) try writer.writeByte(' ');
                var i: usize = 0;
                while (i < padding) : (i += 1) try writer.writeByte(' ');
                try writer.writeAll(welcome_msg[0..display_len]);
            } else {
                var g: usize = 0;
                while (g < lnw) : (g += 1) try writer.writeByte(' ');
                try writer.writeAll("~");
            }
        } else {
            var lnbuf: [16]u8 = undefined;
            const lnstr = std.fmt.bufPrint(&lnbuf, "{d}", .{filerow + 1}) catch unreachable;
            try writer.writeAll("\x1b[2m");
            var pad: usize = lnw - 1 - lnstr.len;
            while (pad > 0) : (pad -= 1) try writer.writeByte(' ');
            try writer.writeAll(lnstr);
            try writer.writeByte(' ');
            try writer.writeAll("\x1b[m");

            const row = E.rows[filerow];
            var len = row.rsize;

            if (E.coloff >= len) {
                len = 0;
            } else {
                len -= E.coloff;
            }

            if (len > content_cols) len = content_cols;

            if (len > 0) {
                const c = row.render[E.coloff .. E.coloff + len];
                const hl = row.hl[E.coloff .. E.coloff + len];
                var current_color: i32 = -1;

                var j: usize = 0;
                while (j < len) : (j += 1) {
                    if (std.ascii.isControl(c[j])) {
                        const sym: u8 = if (c[j] <= 26) '@' + c[j] else '?';
                        try writer.writeAll("\x1b[7m");
                        try writer.writeByte(sym);
                        try writer.writeAll("\x1b[m");
                        if (current_color != -1) {
                            try writer.print("\x1b[{d}m", .{current_color});
                        }
                    } else if (hl[j] == @intFromEnum(editorHighlight.HL_NORMAL)) {
                        if (current_color != -1) {
                            try writer.writeAll("\x1b[39m");
                            current_color = -1;
                        }
                        try writer.writeByte(c[j]);
                    } else {
                        const color = editorSyntaxToColor(hl[j]);
                        if (color != current_color) {
                            current_color = color;
                            try writer.print("\x1b[{d}m", .{color});
                        }
                        try writer.writeByte(c[j]);
                    }
                }
            }

            try writer.writeAll("\x1b[39m");
        }
        try writer.writeAll("\x1b[K");
        try writer.writeAll("\r\n");
    }
}

fn editorSetStatusMessage(comptime fmt: []const u8, args: anytype) void {
    const message = std.fmt.bufPrint(&E.statusmsg, fmt, args) catch {
        E.statusmsg[0] = 0;
        return;
    };
    if (message.len < E.statusmsg.len) {
        E.statusmsg[message.len] = 0;
    }
    E.statusmsg_time = Io.Timestamp.now(io, .real).nanoseconds;
}

//*** input ***//
fn editorPrompt(allocator: mem.Allocator, comptime prompt: []const u8, callback: ?*const fn (mem.Allocator, []const u8, u16) void) !?[]u8 {
    var bufsize: usize = 128;
    var buf = try allocator.alloc(u8, bufsize);
    var buflen: usize = 0;
    buf[0] = 0;

    while (true) {
        editorSetStatusMessage(prompt ++ "{s}", .{buf[0..buflen]});
        try editorRefreshScreen(allocator);

        const c = try editorReadKey();

        if (c == @intFromEnum(editorKey.DEL_KEY) or c == CTRL_KEY('h') or c == @intFromEnum(editorKey.BACKSPACE)) {
            if (buflen > 0) {
                buflen -= 1;
                buf[buflen] = 0;
            }
        } else if (c == '\x1b') {
            editorSetStatusMessage("", .{});
            if (callback) |cb| cb(allocator, buf[0..buflen], c);
            allocator.free(buf);
            return null;
        } else if (c == '\r') {
            if (buflen != 0) {
                editorSetStatusMessage("", .{});
                if (callback) |cb| cb(allocator, buf[0..buflen], c);
                return try allocator.realloc(buf, buflen);
            }
        } else if (c < 128 and !std.ascii.isControl(@intCast(c))) {
            if (buflen == bufsize - 1) {
                bufsize *= 2;
                buf = try allocator.realloc(buf, bufsize);
            }
            buf[buflen] = @intCast(c);
            buflen += 1;
            buf[buflen] = 0;
        }

        if (callback) |cb| cb(allocator, buf[0..buflen], c);
    }
}

fn editorMoveCursor(key: u16) void {
    var row: ?*Erow = if (E.cy < E.numrows) &E.rows[E.cy] else null;

    switch (key) {
        @intFromEnum(editorKey.ARROW_LEFT) => if (E.cx != 0) {
            E.cx -= 1;
        } else if (E.cy > 0) {
            E.cy -= 1;
            const prev_row = &E.rows[E.cy];
            E.cx = @as(u16, @min(prev_row.size, std.math.maxInt(u16)));
        },
        @intFromEnum(editorKey.ARROW_RIGHT) => {
            if (row) |r| {
                if (E.cx < r.size) {
                    E.cx += 1;
                } else if (E.cy < E.numrows - 1) {
                    E.cy += 1;
                    E.cx = 0;
                }
            }
        },
        @intFromEnum(editorKey.ARROW_UP) => if (E.cy != 0) {
            E.cy -= 1;
        },
        @intFromEnum(editorKey.ARROW_DOWN) => if (E.numrows > 0 and E.cy < E.numrows - 1) {
            E.cy += 1;
        },
        else => {},
    }

    row = if (E.cy < E.numrows) &E.rows[E.cy] else null;
    const rowlen = if (row) |r| r.size else 0;
    if (E.cx > rowlen) {
        E.cx = @as(u16, @min(rowlen, std.math.maxInt(u16)));
    }
}

fn editorProcessKeypress(allocator: mem.Allocator) !KeyAction {
    const c = try editorReadKey();

    return switch (c) {
        '\r' => {
            try editorInsertNewline(allocator);
            return .NoOp;
        },

        CTRL_KEY('q') => {
            if (E.dirty > 0 and quit_times > 0) {
                editorSetStatusMessage("WARNING!!! File has unsaved changes. Press Ctrl-Q {d} more times to quit.", .{quit_times});
                quit_times -= 1;
                return .NoOp;
            }

            var stdout_buffer: [1024]u8 = undefined;
            var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
            const stdout = &stdout_writer.interface;

            try stdout.writeAll("\x1b[2J");
            try stdout.writeAll("\x1b[H");
            try stdout.flush();
            return .Quit;
        },
        CTRL_KEY('s') => {
            try editorSave(allocator);
            return .NoOp;
        },
        @intFromEnum(editorKey.HOME_KEY) => {
            E.cx = 0;
            return .NoOp;
        },
        @intFromEnum(editorKey.END_KEY) => {
            if (E.cy < E.numrows) {
                E.cx = @intCast(E.rows[E.cy].size);
            }
            return .NoOp;
        },

        CTRL_KEY('z') => {
            try editorUndo(allocator);
            return .NoOp;
        },
        CTRL_KEY('y') => {
            try editorRedo(allocator);
            return .NoOp;
        },

        CTRL_KEY('f') => {
            try editorFind(allocator);
            return .NoOp;
        },

        @intFromEnum(editorKey.BACKSPACE), CTRL_KEY('h'), @intFromEnum(editorKey.DEL_KEY) => {
            if (c == @intFromEnum(editorKey.DEL_KEY)) {
                editorMoveCursor(@intFromEnum(editorKey.ARROW_RIGHT));
            }
            try editorDelChar(allocator);
            return .NoOp;
        },

        @intFromEnum(editorKey.PAGE_UP), @intFromEnum(editorKey.PAGE_DOWN) => {
            if (c == @intFromEnum(editorKey.PAGE_UP)) {
                E.cy = E.rowoff;
            } else {
                E.cy = E.rowoff + E.screenrows - 1;
                if (E.cy > E.numrows) E.cy = E.numrows;
            }

            var times = E.screenrows;
            while (times != 0) : (times -= 1) {
                editorMoveCursor(if (c == @intFromEnum(editorKey.PAGE_UP))
                    @intFromEnum(editorKey.ARROW_UP)
                else
                    @intFromEnum(editorKey.ARROW_DOWN));
            }
            return .NoOp;
        },

        @intFromEnum(editorKey.ARROW_UP), @intFromEnum(editorKey.ARROW_DOWN), @intFromEnum(editorKey.ARROW_LEFT), @intFromEnum(editorKey.ARROW_RIGHT) => {
            editorMoveCursor(c);
            return .NoOp;
        },

        CTRL_KEY('l'), '\x1b' => .NoOp,

        else => {
            if (fnPressed) {
                switch (c) {
                    'w' => editorMoveCursor(@intFromEnum(editorKey.ARROW_UP)),
                    'a' => editorMoveCursor(@intFromEnum(editorKey.ARROW_LEFT)),
                    's' => editorMoveCursor(@intFromEnum(editorKey.ARROW_DOWN)),
                    'd' => editorMoveCursor(@intFromEnum(editorKey.ARROW_RIGHT)),
                    else => try editorInsertChar(allocator, @intCast(c)),
                }
            } else {
                try editorInsertChar(allocator, @intCast(c));
            }
            quit_times = KZ_QUIT_TIMES;
            return .NoOp;
        },
    };
}

//*** init ***//
fn initEditor() void {
    E.cx = 0;
    E.cy = 0;
    E.rx = 0;
    E.rowoff = 0;
    E.coloff = 0;
    E.numrows = 0;
    E.rows = &[0]Erow{};
    E.filename = null;
    E.dirty = 0;
    E.statusmsg[0] = 0;
    E.statusmsg_time = 0;
    E.syntax = null;
    undo_len = 0;
    redo_len = 0;

    getWindowSize(&E.screenrows, &E.screencols) catch {
        // Fallback values if we can't get terminal size for some reason
        E.screenrows = 24;
        E.screencols = 80;
    };
    E.screenrows -= 2;
}

pub fn main(init: std.process.Init) anyerror!void {
    io = init.io;
    const allocator = init.arena.allocator();

    try enableRawMode();
    defer disableRawMode();
    initEditor();

    const args = try init.minimal.args.toSlice(allocator);

    if (args.len > 1) {
        try editorOpen(allocator, args[1]);
    }

    editorSetStatusMessage("HELP: Ctrl-S = save | Ctrl-Q = quit | Ctrl-F = find | Ctrl-Z = undo | Ctrl-Y = redo", .{});

    while (true) {
        try editorRefreshScreen(allocator);
        switch (try editorProcessKeypress(allocator)) {
            .Quit => break,
            else => {},
        }
    }
}
