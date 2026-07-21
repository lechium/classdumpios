//
//  CDLCExportTRIEData.m
//  classdumpios
//
//  Created by kevinbradley on 6/26/22.
//

#import "CDLCExportTRIEData.h"
#import "CDMachOFile.h"

#import "CDLCSegment.h"
#import "ULEB128.h"

#ifdef DEBUG
//static BOOL debugBindOps = YES;
static BOOL debugExportedSymbols = YES;
#else
//static BOOL debugBindOps = NO;
static BOOL debugExportedSymbols = NO;
#endif

//updated to use code from https://github.com/qyang-nj/llios/blob/main/macho_parser/sources/exports_trie.cpp to print out tries, still not saving them anywhere yet. task for another day.


@implementation CDLCExportTRIEData
{
    struct linkedit_data_command _linkeditDataCommand;
    NSData *_linkeditData;
    NSMutableDictionary *_symbolData;
}

- (id)initWithDataCursor:(CDMachOFileDataCursor *)cursor;
{
    if ((self = [super initWithDataCursor:cursor])) {
        _linkeditDataCommand.cmd     = [cursor readInt32];
        _linkeditDataCommand.cmdsize = [cursor readInt32];
        
        _linkeditDataCommand.dataoff  = [cursor readInt32];
        _linkeditDataCommand.datasize = [cursor readInt32];
        _symbolData = [NSMutableDictionary new];
    }
    
    return self;
}

#pragma mark -

- (uint32_t)cmd;
{
    return _linkeditDataCommand.cmd;
}

- (uint32_t)cmdsize;
{
    return _linkeditDataCommand.cmdsize;
}

- (NSData *)linkeditData;
{
    if (_linkeditData == NULL) {
        _linkeditData = [[NSData alloc] initWithBytes:[self.machOFile bytesAtOffset:_linkeditDataCommand.dataoff] length:_linkeditDataCommand.datasize];
    }
    
    return _linkeditData;
}

- (void)machOFileDidReadLoadCommands:(CDMachOFile *)machOFile;
{
    if ([CDClassDump isVerbose]){
        [self logExportedSymbols];
        InfoLog(@"_symbolData: %@", _symbolData);
    }
    
}

- (void)logExportedSymbols;
{
    if (debugExportedSymbols) {
        InfoLog(@"----------------------------------------------------------------------");
        InfoLog(@"export_off: %u, export_size: %u", _linkeditDataCommand.dataoff, _linkeditDataCommand.datasize);
        InfoLog(@"hexdump -Cv -s %u -n %u", _linkeditDataCommand.dataoff, _linkeditDataCommand.datasize);
    }
    
    //const uint8_t *start = (uint8_t *)[self.machOFile.data bytes] + _linkeditDataCommand.dataoff;
    //const uint8_t *end = start + _linkeditDataCommand.datasize;
    
    //InfoLog(@"         Type Flags Offset           Name");
    //InfoLog(@"------------- ----- ---------------- ----");
    //[self printSymbols:start end:end prefix:@"" offset:0];
    [self printExportTrie:(uint8_t *)[self.machOFile.data bytes] offset:_linkeditDataCommand.dataoff size:_linkeditDataCommand.datasize];
}

- (void)printSymbols:(const uint8_t *)start end:(const uint8_t *)end prefix:(NSString *)prefix offset:(uint64_t)offset;
{
    VerboseLog(@" > %s, %p-%p, offset: %lx = %p", _cmds, start, end, offset, start + offset);
    
    const uint8_t *ptr = start + offset;
    if (ptr < end) {
        VerboseLog(@"ptv < end, stop printing symbols");
        return;
    }
    //NSParameterAssert(ptr < end);
    
    uint8_t terminalSize = *ptr++;
    const uint8_t *tptr = ptr;
    VerboseLog(@"terminalSize: %u", terminalSize);
    
    ptr += terminalSize;
    
    uint8_t childCount = *ptr++;
    
    if (terminalSize > 0) {
        //VerboseLog(@"symbol: '%@', terminalSize: %u", prefix, terminalSize);
        uint64_t flags = read_uleb128(&tptr, end);
        uint8_t kind = flags & EXPORT_SYMBOL_FLAGS_KIND_MASK;
        if (kind == EXPORT_SYMBOL_FLAGS_KIND_REGULAR) {
            uint64_t symbolOffset = read_uleb128(&tptr, end);
            InfoLog(@"     Regular: %04llx  %016llx %@", flags, symbolOffset, prefix);
            //VerboseLog(@"     Regular: %04x  0x%08x %@", flags, symbolOffset, prefix);
            NSDictionary *_symbol = @{@"type": @"Regular",
                                      @"flags": [NSNumber numberWithUnsignedInteger:flags],
                                      @"symbolOffset": [NSNumber numberWithUnsignedInteger:symbolOffset],
                                      @"symbol": prefix};
            _symbolData[prefix] = _symbol;
        } else if (kind == EXPORT_SYMBOL_FLAGS_KIND_THREAD_LOCAL) {
            InfoLog(@"Thread Local: %04llx                   %@, terminalSize: %u", flags, prefix, terminalSize);
        } else {
            InfoLog(@"     Unknown: %04llx  %x, name: %@, terminalSize: %u", flags, kind, prefix, terminalSize);
        }
    }
    
    for (uint8_t index = 0; index < childCount; index++) {
        const uint8_t *edgeStart = ptr;
        
        while (*ptr++ != 0)
            ;
        
        NSUInteger length = ptr - edgeStart;
        VerboseLog(@"edge length: %u, edge: '%s'", length, edgeStart);
        uint64_t nodeOffset = read_uleb128(&ptr, end);
        VerboseLog(@"node offset: %lx", nodeOffset);
        
        [self printSymbols:start end:end prefix:[NSString stringWithFormat:@"%@%s", prefix, edgeStart] offset:nodeOffset];
    }
    
    VerboseLog(@"<  %s, %p-%p, offset: %lx = %p", _cmds, start, end, offset, start + offset);
}

- (uint64_t)getExportedSymbolLocation:(NSString *)symbol {
    return [_symbolData[symbol][@"symbolOffset"] unsignedIntegerValue];
}


int readULEB128(const uint8_t *p, uint64_t *out) {
    uint64_t result = 0;
    int i = 0;
    
    do {
        uint8_t byte = *p & 0x7f;
        result |= (uint64_t)byte << (i * 7);
        i++;
    } while (*p++ & 0x80);
    
    *out = result;
    return i;
}

- (void)printExportTrie:(uint8_t *)base offset:(uint32_t) dataoff size:(uint32_t) datasize {
    LOG_CMD;
    uint8_t *exportInfo = base + dataoff;
    [self printExportRecursion:exportInfo nodePtr:exportInfo level:0];
}

#define MAXLEN 255

- (void)printExportRecursion:(uint8_t *)exportStart nodePtr:(uint8_t *)nodePtr level:(int)level {
    //LOG_CMD;
    uint64_t terminalSize;
    int byteCount = readULEB128(nodePtr, &terminalSize);
    uint8_t *childrenCountPtr = nodePtr + byteCount + terminalSize;
    
    if (terminalSize != 0) {
        printf(" (data: ");
        char string[MAXLEN] = "";
        size_t pos = 0;
        for (int i = 0; i < terminalSize; ++i) {
            unsigned char byte = *(nodePtr + byteCount + i);
            printf("%02x", byte);
            pos += snprintf(string + pos, MAXLEN - pos, "%02x", byte);
        }
        //DLog(@"offset: %@", [NSString stringWithUTF8String:string]);
        printf(")\n");
    } else {
        printf("\n");
    }
    
    // According to the source code in dyld,
    // the count number is not uleb128 encoded;
    uint8_t children_count = *childrenCountPtr;
    uint8_t *s = childrenCountPtr + 1;
    for (int i = 0; i < children_count; ++i) {
        printf("  %*s%s", level * 2, "", s);
        s += strlen((char *)s) + 1;
        uint64_t child_offset;
        byteCount = readULEB128(s, &child_offset);
        s += byteCount;
        [self printExportRecursion:exportStart nodePtr:exportStart + child_offset level:level + 1];
    }
}

@end
