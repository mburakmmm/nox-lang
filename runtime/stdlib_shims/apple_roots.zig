//! iOS sistem kök sertifikaları. Zig'in `Certificate.Bundle.rescan`ı
//! anahtarlığı yalnız macOS'ta okur; simülatörde aynı dosya vardır.

const std = @import("std");

const x509_certificate: u32 = 0x80001000;

const ApplDbHeader = extern struct {
    signature: [4]u8,
    version: u32,
    header_size: u32,
    schema_offset: u32,
    auth_offset: u32,
};

const ApplDbSchema = extern struct {
    schema_size: u32,
    table_count: u32,
};

const TableHeader = extern struct {
    table_size: u32,
    table_id: u32,
    record_count: u32,
    records: u32,
    indexes_offset: u32,
    free_list_head: u32,
    record_numbers_count: u32,
};

const X509CertHeader = extern struct {
    record_size: u32,
    record_number: u32,
    unknown1: u32,
    unknown2: u32,
    cert_size: u32,
    unknown3: u32,
    cert_type: u32,
    cert_encoding: u32,
    print_name: u32,
    alias: u32,
    subject: u32,
    issuer: u32,
    serial_number: u32,
    subject_key_identifier: u32,
    public_key_hash: u32,
};

pub fn fill(bundle: *std.crypto.Certificate.Bundle, gpa: std.mem.Allocator, io: std.Io, now: std.Io.Timestamp) bool {
    const paths = [_][]const u8{
        "/System/Library/Keychains/SystemRootCertificates.keychain",
        "/Library/Keychains/System.keychain",
    };
    var loaded: usize = 0;
    for (paths) |path| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(std.math.maxInt(u32))) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return loaded != 0,
        };
        defer gpa.free(bytes);
        var reader: std.Io.Reader = .fixed(bytes);
        scan(&reader, bundle, gpa, now.toSeconds()) catch return false;
        loaded += 1;
    }
    return loaded != 0;
}

fn scan(reader: *std.Io.Reader, bundle: *std.crypto.Certificate.Bundle, gpa: std.mem.Allocator, now_sec: i64) !void {
    const db_header = try reader.takeStruct(ApplDbHeader, .big);
    if (!std.mem.eql(u8, &db_header.signature, "kych")) return error.BadKeychain;
    reader.seek = db_header.schema_offset;
    const db_schema = try reader.takeStruct(ApplDbSchema, .big);
    const table_list = try gpa.alloc(u32, db_schema.table_count);
    defer gpa.free(table_list);
    for (table_list) |*table| table.* = try reader.takeInt(u32, .big);
    for (table_list) |table_offset| {
        reader.seek = db_header.schema_offset + table_offset;
        const table_header = try reader.takeStruct(TableHeader, .big);
        if (table_header.table_id != x509_certificate) continue;
        const record_list = try gpa.alloc(u32, table_header.record_count);
        defer gpa.free(record_list);
        for (record_list) |*record| record.* = try reader.takeInt(u32, .big);
        for (record_list) |record_offset| {
            if (record_offset == 0 or record_offset % 4 != 0) continue;
            reader.seek = db_header.schema_offset + table_offset + record_offset;
            const cert_header = try reader.takeStruct(X509CertHeader, .big);
            if (cert_header.cert_size == 0) continue;
            const cert_start: u32 = @intCast(bundle.bytes.items.len);
            const dest = try bundle.bytes.addManyAsSlice(gpa, cert_header.cert_size);
            try reader.readSliceAll(dest);
            try bundle.parseCert(gpa, cert_start, now_sec);
        }
    }
}
