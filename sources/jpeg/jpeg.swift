import Glibc

enum JPEGReadError:Error
{
    case FileError(String),
         FiletypeError,
         FilestreamError,
         MissingJFIFHeader,
         InvalidJFIFHeader,
         MissingFrameHeader,
         InvalidFrameHeader,
         MissingScanHeader,
         InvalidScanHeader,

         InvalidQuantizationTable,
         InvalidHuffmanTable,

         InvalidDNLSegment,

         StructuralError,
         SyntaxError(String),

         Unsupported(String), 
         
         Unimplemented(String)
}

func resolvePath(_ path:String) -> String
{
    guard let first:Character = path.first
    else
    {
        return path
    }

    if first == "~"
    {
        let expanded:String.SubSequence = path.dropFirst()
        if  expanded.isEmpty ||
            expanded.first == "/"
        {
            return String(cString: getenv("HOME")) + expanded
        }

        return path
    }

    return path
}

extension UnsafeRawBufferPointer
{
    func loadBigEndian<I>(fromByteOffset offset:Int, as _:I.Type)
        -> I where I:FixedWidthInteger
    {
        var i:I = .init()
        withUnsafeMutablePointer(to: &i)
        {
            UnsafeMutableRawPointer($0).copyMemory(from: self.baseAddress! + offset,
                byteCount: MemoryLayout<I>.size)
        }

        return I(bigEndian: i)
    }
}

// TODO: implement buffering
func readUInt8(from stream:UnsafeMutablePointer<FILE>) throws -> UInt8
{
    var uint8:UInt8 = 0
    return try withUnsafeMutablePointer(to: &uint8)
    {
        guard fread($0, 1, 1, stream) == 1
        else
        {
            throw JPEGReadError.FilestreamError
        }

        return $0.pointee
    }
}

func readBigEndian<I>(from stream:UnsafeMutablePointer<FILE>, as:I.Type) throws
    -> I where I:FixedWidthInteger
{
    var i:I = .init()
    return try withUnsafeMutablePointer(to: &i)
    {
        guard fread($0, MemoryLayout<I>.size, 1, stream) == 1
        else
        {
            throw JPEGReadError.FilestreamError
        }

        return I(bigEndian: $0.pointee)
    }
}

// reads length block and allocates output buffer
func readMarkerData(from stream:UnsafeMutablePointer<FILE>)
    throws -> UnsafeRawBufferPointer
{
    let length:Int = Int(try readBigEndian(from: stream, as: UInt16.self)) - 2
    let dest:UnsafeMutableRawBufferPointer = 
        .allocate(byteCount: length, alignment: MemoryLayout<UInt>.alignment)

    guard fread(dest.baseAddress, 1, length, stream) == length
    else
    {
        throw JPEGReadError.FilestreamError
    }

    return UnsafeRawBufferPointer(dest)
}

func readNextMarker(from stream:UnsafeMutablePointer<FILE>) throws -> UInt8
{
    guard try readUInt8(from: stream) == 0xff
    else
    {
        throw JPEGReadError.StructuralError
    }

    while true
    {
        let marker:UInt8 = try readUInt8(from: stream)
        if marker != 0xff
        {
            return marker
        }
    }
}

enum QuantizationTable
{
    case q8 ([UInt8]),
         q16([UInt16])

    static
    func createQ8(data:UnsafeRawPointer) -> QuantizationTable
    {
        return .q8([UInt8](UnsafeRawBufferPointer(start: data, count: 64)))
    }

    static
    func createQ16(data:UnsafeRawPointer) -> QuantizationTable
    {
        let u16:UnsafePointer<UInt16> = data.bindMemory(to: UInt16.self, capacity: 64)
        return .q16(UnsafeBufferPointer<UInt16>(start: u16, count: 64).map(UInt16.init(bigEndian:)))
    }
}

struct HuffmanTable
{
    typealias Entry = (value:UInt8, length:UInt8)
    
    private 
    let storage:[Entry], 
        n:Int, // number of level 0 entries
        ζ:Int  // logical size of the table (where the n level 0 entries are each 256 units big)

    // determine the value of n, explained in create(leafCounts:leafValues:coefficientClass),
    // as well as the useful size of the table (often, a large region of the high codeword 
    // space is unused so it can be excluded)
    // also validates leaf counts to make sure they define a valid 16-bit tree
    private static
    func precalculateSizeParameters(_ leafCounts:UnsafePointer<UInt8>) -> (n:Int, z:Int)?
    {
        var internalNodes:Int = 1 // count the root 
        for l:Int in 0 ..< 8 
        {
            guard internalNodes > 0 
            else 
            {
                return nil
            }
            
            // every internal node on the level above generates two new nodes.
            // some of the new nodes are leaf nodes, the rest are internal nodes.
            internalNodes = internalNodes &<< 1 - Int(leafCounts[l])
        }
        
        // the number of internal nodes remaining is the number of child trees, with 
        // the possible exception of a fake all-ones branch 
        let n:Int      = 256 - internalNodes 
        var z:Int      = n, 
            shadow:Int = 0x80
        
        // finish validating the tree 
        for l:Int in 8 ..< 16 
        {
            guard internalNodes > 0 
            else 
            {
                return nil
            }
            
            let leaves:Int = .init(leafCounts[l])
            z             += leaves * shadow
            
            internalNodes = internalNodes &<< 1 - leaves 
            shadow      >>= 1
        }
        
        guard internalNodes > 0
        else 
        {
            return nil
        }
        
        return (n, z)
    }

    static 
    func create(leafCounts:UnsafePointer<UInt8>, leafValues:UnsafePointer<UInt8>) 
        -> HuffmanTable?
    {
        /*
        idea:    jpeg huffman tables are encoded gzip style, as sequences of
                 leaf counts and leaf values. the leaf counts tell you the
                 number of leaf nodes at each level of the tree. combined with
                 a rule that says that leaf nodes always occur on the “leftmost”
                 side of the tree, this uniquely determines a huffman tree.
        
                 Given: leaves per level = [0, 3, 1, 1, ... ]
        
                         ___0___[root]___1___
                       /                      \
                __0__[ ]__1__            __0__[ ]__1__
              /              \         /               \
             [a]            [b]      [c]            _0_[ ]_1_
                                                  /           \
                                                [d]        _0_[ ]_1_
                                                         /           \
                                                       [e]        reserved
        
                 note that in a huffman tree, level 0 always contains 0 leaf
                 nodes (why?) so the huffman table omits level 0 in the leaf
                 counts list.
        
                 we *could* build a tree data structure, and traverse it as
                 we read in the coded bits, but that would be slow and require
                 a shift for every bit. instead we extend the huffman tree
                 into a perfect tree, and assign the new leaf nodes the
                 values of their parents.
        
                             ________[root]________
                           /                        \
                   _____[ ]_____                _____[ ]_____
                  /             \             /               \
                 [a]           [b]          [c]            ___[ ]___
               /     \       /     \       /   \         /           \
             (a)     (a)   (b)     (b)   (c)   (c)      [d]          ...
        
                 this lets us make a table of huffman codes where all the
                 codes are “padded” to the same length. note that codewords
                 that occur higher up the tree occur multiple times because
                 they have multiple children. of course, since the extra bits
                 aren’t actually part of the code, we have to store separately
                 the length of the original code so we know how many bits
                 we should advance the current bit position by once we match
                 a code.
        
                   code       value     length
                 —————————  —————————  ————————
                    000        'a'         2
                    001        'a'         2
                    010        'b'         2
                    011        'b'         2
                    100        'c'         2
                    101        'c'         2
                    110        'd'         3
                    111        ...        >3
        
                 decoding coded data then becomes a matter of matching a fixed
                 length bitstream against the table (the code works as an integer
                 index!) since all possible combinations of trailing “padding”
                 bits are represented in the table.
        
                 in jpeg, codewords can be a maximum of 16 bits long. this
                 means in theory we need a table with 2^16 entries. that’s a
                 huge table considering there are only 256 actual encoded
                 values, and since this is the kind of thing that really needs
                 to be optimized for speed, this needs to be as cache friendly
                 as possible.
        
                 we can reduce the table size by splitting the 16-bit table
                 into two 8-bit levels. this means we have one 8-bit “root”
                 tree, and k 8-bit child trees rooted on the internal nodes
                 at level 8 of the original tree.
        
                 so far, we’ve looked at the huffman tree as a tree. however 
                 it actually makes more sense to look at it as a table, just 
                 like its implementation. remember that the tree is right-heavy, 
                 so the first 8 levels will look something like 
        
                 +———————————————————+ 0
                 |                   |
                 |                   |
                 |                   |
                 |                   |
                 |                   |
                 |                   |
                 |                   |
                 +———————————————————+
                 |                   |
                 |                   |
                 |                   |
                 +———————————————————+
                 |                   |
                 |                   |
                 |                   |
                 +———————————————————+ -
                 |                   |
                 +———————————————————+
                 |                   |
                 +———————————————————+
                 |                   |
                 +———————————————————+
                 |                   |
                 +———————————————————+ -
                 |                   |
                 +———————————————————+
                 +———————————————————+
               n +———————————————————+ -    —    +———————————————————+ s = 0
                 +-------------------+      ↑    |                   |
                 +-------------------+      s    |                   |
                 +-------------------+      ↓    |                   |
           n + s +-------------------+ 256  —    +———————————————————+
                                                 |                   |
                                                 |                   |
                                                 |                   |
                                                 +———————————————————+
                                                 |                   |
                                                 |                   |
                                                 |                   |
                                                 +———————————————————+
                                                 |                   |
                                                 +———————————————————+
                                                 |                   |
                                                 /////////////////////
        
                 this is awesome because we don’t need to store anything in 
                 the table entries themselves to know if they are direct entries 
                 or indirect entries. if the index of the entry is greater than 
                 or equal to `n` (the number of direct entries), it is an 
                 indirect entry, and its indirect index is given by the first 
                 byte of the codeword with `n` subtracted from it. 
                 level-1 subtables are always 256 entries long since they are 
                 leaf tables. this means their positions can be computed in 
                 constant time, given `n`, which is also the position of the 
                 first level-1 table.
                 
                 (for computational ease, we store `s = 256 - n` instead. 
                 `s` can be interpreted as the number of level-1 subtables 
                 trail the level-0 table in the storage buffer)
        
                 how big can `s` be? well, remember that there are only 256
                 different encoded values which means the original tree can
                 only have 256 leaves. any full binary tree with height at
                 least 1 *must* contain at least 2 leaf nodes (why?). since
                 the child trees must have a height > 0 (otherwise they would
                 be 0-bit trees), every child tree except possibly the right-
                 most one must have at least 2 leaf nodes. the rightmost child
                 tree is an exception because in jpeg, the all-ones codeword
                 does not represent any value, so the right-most tree can
                 possibly only contain one “real” leaf node. we can pigeonhole
                 this to show that we can only have up to k ≤ 129 child trees.
                 in fact, we can reduce this even further to k ≤ 128 because
                 if the rightmost tree only contains 1 leaf, there has to be at
                 least one other tree with an odd number of leaves to make the  
                 total add up to 256, and that number has to be at least 3. 
                 in reality, k is rarely bigger than 7 or 8 yielding a significant 
                 size savings.
        
                 because we don’t need to store pointers, each table entry can 
                 be just 2 bytes long — 1 byte for the encoded value, and 1 byte 
                 to store the length of the codeword.
        
                 a buffer like this will never have size greater than
                 2 * 256 × (128 + 1) = 65_792 bytes, compared with
                 2 × (1 << 16)  = 131_072 bytes for the 16-bit table. in
                 reality the 2 layer table is usually on the order of 2–4 kB.
        
                 why not compact the child trees further, since not all of them
                 actually have height 8? we could do that, and get some serious
                 worst-case memory savings, but then we couldn’t access the
                 child tables at constant offsets from the buffer base. we’d
                 need to store whole ass ≥16-bit pointers to the specific
                 byte offset where the variable-length child table lives, and
                 perform a conditional bit shift to transform the input bits
                 into an appropriate index into the table. not a good look.
        */
        
        // z is the physical size of the table in memory
        guard let (n, z):(Int, Int) = precalculateSizeParameters(leafCounts) 
        else 
        {
            return nil
        }
        
        var storage:[Entry] = []
            storage.reserveCapacity(z)
        
        var value:UnsafePointer<UInt8> = leafValues, 
            shadow:Int                 = 0x8080
        for l:Int in 0 ..< 16
        {
            guard storage.count < z 
            else 
            {
                break
            }            
            
            let length:UInt8 = .init(truncatingIfNeeded: l + 1)
            for _ in 0 ..< leafCounts[l]
            {
                let limit:Int = storage.count + shadow & 0xff
                while (storage.count < limit)
                {
                    storage.append((value: value.pointee, length: length))
                }
                
                value += 1
            }
            
            shadow >>= 1
        }
        
        assert(storage.count == z)
        
        return .init(storage: storage, n: n, ζ: z + n * 255)
    }
    
    // codeword is big-endian
    subscript(codeword:UInt16) -> Entry 
    {
        // [ level 0 index  |    offset    ]
        let i:Int = .init(codeword >> 8)
        if i < self.n 
        {
            return self.storage[i]
        }
        else 
        {
            guard Int(codeword) < self.ζ 
            else 
            {
                return (0, 16)
            }
            
            return self.storage[Int(codeword) - self.n * 255]
        }
    }
}

struct JFIF
{
    enum DensityUnit:UInt8
    {
        case none = 0,
             dpi  = 1,
             dpcm = 2
    }

    let version:(major:UInt8, minor:UInt8),
        densityUnit:DensityUnit,
        density:(x:UInt16, y:UInt16)

    static
    func read(from stream:UnsafeMutablePointer<FILE>, marker:inout UInt8)
        throws -> JFIF?
    {
        guard marker == 0xe0
        else
        {
            throw JPEGReadError.MissingJFIFHeader
        }

        let data:UnsafeRawBufferPointer = try readMarkerData(from: stream)
        marker = try readNextMarker(from: stream)
        return JFIF.create(from: data)
    }

    private static 
    func create(from data:UnsafeRawBufferPointer) -> JFIF?
    {
        guard data.count >= 14
        else
        {
            return nil
        }

        guard   data[0] == 0x4a, 
                data[1] == 0x46, 
                data[2] == 0x49, 
                data[3] == 0x46, 
                data[4] == 0x00
        else 
        {
            // missing 'JFIF' signature"
            return nil
        }

        let version:(major:UInt8, minor:UInt8)
        version.major = data.load(fromByteOffset: 5, as: UInt8.self)
        version.minor = data.load(fromByteOffset: 6, as: UInt8.self)

        guard version.major == 1, 0 ... 2 ~= version.minor
        else
        {
            // bad JFIF version number (expected 1.0 ... 1.2)
            return nil
        }

        guard let densityUnit:DensityUnit =
            DensityUnit.init(rawValue: data.load(fromByteOffset: 7, as: UInt8.self))
        else
        {
            // invalid JFIF density unit
            return nil
        }

        let density:(x:UInt16, y:UInt16)
        density.x = data.loadBigEndian(fromByteOffset:  8, as: UInt16.self)
        density.y = data.loadBigEndian(fromByteOffset: 10, as: UInt16.self)

        // we ignore the thumbnail data
        return JFIF(version: version, densityUnit: densityUnit, density: density)
    }
}

struct FrameHeader
{
    enum Encoding
    {
        case baselineDCT,
             extendedDCT,
             progressiveDCT
    }

    struct Component
    {
        private
        let _sampleFactors:UInt8

        let q:UInt8

        var sampleFactors:(x:UInt8, y:UInt8)
        {
            return (self._sampleFactors >> 4, self._sampleFactors & 0x0f)
        }

        init?(sampleFactors:UInt8, q:UInt8)
        {
            guard 1 ... 4 ~= sampleFactors >> 4,
                  1 ... 4 ~= sampleFactors & 0x0f,
                  0 ... 3 ~= q
            else
            {
                return nil
            }

            self._sampleFactors = sampleFactors
            self.q              = q
        }
    }

    let encoding:Encoding,
        precision:Int,
        width:Int

    internal private(set) // DNL segment may change this later on
    var height:Int

    let components:[Component?]

    static
    func read(from stream:UnsafeMutablePointer<FILE>, marker:inout UInt8) throws
        -> FrameHeader?
    {
        let data:UnsafeRawBufferPointer,
            encoding:Encoding

        switch marker
        {
        case 0xc0:
            data     = try readMarkerData(from: stream)
            encoding = .baselineDCT

        case 0xc1:
            data     = try readMarkerData(from: stream)
            encoding = .extendedDCT

        case 0xc2:
            data     = try readMarkerData(from: stream)
            encoding = .progressiveDCT

        case 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf:
            throw JPEGReadError.Unsupported("unsupported frame encoding (encoding type \(marker & 0xf))")

        default:
            throw JPEGReadError.MissingFrameHeader
        }

        defer
        {
            data.deallocate()
        }

        marker = try readNextMarker(from: stream)
        return create(from: data, encoding: encoding)
    }

    private static
    func create(from data:UnsafeRawBufferPointer, encoding:Encoding)
        -> FrameHeader?
    {
        guard data.count >= 6
        else
        {
            return nil
        }

        let precision:UInt8 = data.load(fromByteOffset: 0, as: UInt8.self)
        switch encoding
        {
        case .baselineDCT:
            guard precision == 8
            else
            {
                return nil
            }

        case .extendedDCT, .progressiveDCT:
            guard precision == 8 || precision == 12
            else
            {
                return nil
            }
        }

        let height:UInt16 = data.loadBigEndian(fromByteOffset: 1, as: UInt16.self),
            width:UInt16  = data.loadBigEndian(fromByteOffset: 3, as: UInt16.self)

        let count:Int     = .init(data.load(fromByteOffset: 5, as: UInt8.self))

        if encoding == .progressiveDCT
        {
            guard 1 ... 4 ~= count
            else
            {
                return nil
            }
        }
        else 
        {
            guard count > 0
            else
            {
                return nil
            }
        }

        guard 3 * count == data.count - 6
        else
        {
            return nil
        }

        var components:[Component?] = .init(repeating: nil, count: 256)
        for i:Int in 0 ..< count
        {
            let ci:Int = .init(data.load(fromByteOffset: 6 + 3 * i, as: UInt8.self))
            
            // make sure no duplicate component indices are used 
            guard components[ci] == nil 
            else 
            {
                return nil
            }
            
            guard let component:Component = Component.init(
                sampleFactors: data.load(fromByteOffset: 7 + 3 * i, as: UInt8.self),
                q:             data.load(fromByteOffset: 8 + 3 * i, as: UInt8.self))
            else
            {
                return nil
            }

            components[ci] = component
        }

        return FrameHeader(encoding: encoding,
            precision:  Int(precision),
            width:      Int(width),
            height:     Int(height),
            components: components)
    }

    mutating
    func updateHeight(from stream:UnsafeMutablePointer<FILE>, marker:inout UInt8)
        throws
    {
        guard marker == 0xdc
        else
        {
            return
        }

        let data:UnsafeRawBufferPointer = try readMarkerData(from: stream)
        defer
        {
            data.deallocate()
        }

        guard data.count == 2
        else
        {
            throw JPEGReadError.InvalidDNLSegment
        }

        self.height = Int(data.loadBigEndian(fromByteOffset: 0, as: UInt16.self))
    }
}

struct ScanHeader
{
    struct Component 
    {
        let component:Int, 
            selectors:(dc:Int, ac:Int)
        
        init(data:(UInt8, UInt8))
        {
            self.component    = Int(data.0)
            self.selectors.dc = Int(data.1 >> 4)
            self.selectors.ac = Int(data.1 & 0xf)
        }
    }
    
    let band:Range<Int>, 
        exponent:Int, 
        components:[Component] // FSA4
    
    // the marker parameter is not a reference because this function does not
    // update the `marker` variable because scan headers are followed by MCU data
    static
    func read(from stream:UnsafeMutablePointer<FILE>, marker:UInt8) throws
        -> ScanHeader?
    {
        guard marker == 0xda
        else
        {
            throw JPEGReadError.MissingScanHeader
        }

        let data:UnsafeRawBufferPointer = try readMarkerData(from: stream)
        defer
        {
            data.deallocate()
        }

        return create(from: data)
    }

    private static 
    func create(from data:UnsafeRawBufferPointer) -> ScanHeader?
    {
        guard data.count >= 4 
        else 
        {
            return nil
        }
        
        let count:Int = .init(data.load(fromByteOffset: 0, as: UInt8.self))
        
        guard   1 ... 4 ~= count, 
                data.count - 4 >= count * 2 
        else 
        {
            return nil
        }
        
        
        let components:[Component] = (0 ..< count).map 
        {
            .init(data: (data.load(fromByteOffset: $0 << 1 + 1, as: UInt8.self), 
                         data.load(fromByteOffset: $0 << 1 + 2, as: UInt8.self)))
        }
        
        // TODO: validate sampling factor sum 
        
        let band:(UInt8, UInt8) = 
            (data.load(fromByteOffset: data.count - 3, as: UInt8.self), 
             data.load(fromByteOffset: data.count - 2, as: UInt8.self))
        let bits:UInt8 = data.load(fromByteOffset: data.count - 1, as: UInt8.self)
        
        // need to validate Ah parameter
        
        return ScanHeader(
            band      : Int(band.0    ) ..< Int(band.1   ) + 1, 
            exponent  : Int(bits & 0xf), 
            components: components)
    }
}

struct Context
{
    internal private(set)
    var restartInterval:Int = 0

    // these must be managed manually or they will leak
    private
    var qtables:(QuantizationTable?,
                 QuantizationTable?,
                 QuantizationTable?,
                 QuantizationTable?) = (nil, nil, nil, nil)

    private
    var dctables:(HuffmanTable?,
                  HuffmanTable?,
                  HuffmanTable?,
                  HuffmanTable?) = (nil, nil, nil, nil)
    private
    var actables:(HuffmanTable?,
                  HuffmanTable?,
                  HuffmanTable?,
                  HuffmanTable?) = (nil, nil, nil, nil)

    // restart is a naked marker so it takes no `stream` parameter. just like
    // ScanHeader.read(from:marker:) this function does not update the `marker`
    // variable because restart markers are followed by MCU data
    func restart(marker:UInt8) -> Bool
    {
        return 0xd0 ... 0xd7 ~= marker
    }

    mutating // todo: rewrite with buffers and no throws
    func update(from stream:UnsafeMutablePointer<FILE>, marker:inout UInt8) throws
    {
        while true
        {
            let data:UnsafeRawBufferPointer
            switch marker
            {
            case 0xdb: // define quantization table(s)
                data = try readMarkerData(from: stream)
                guard let _:Void = self.updateQuantizationTables(from: data)
                else
                {
                    data.deallocate()
                    throw JPEGReadError.InvalidQuantizationTable
                }

            case 0xc4: // define huffman table(s)
                data = try readMarkerData(from: stream)
                guard let _:Void = self.updateHuffmanTables(from: data)
                else
                {
                    data.deallocate()
                    throw JPEGReadError.InvalidHuffmanTable
                }
            
            case 0xcc:
                throw JPEGReadError.Unsupported("arithmetic encoding is unsupported")

            case 0xdd: // define restart interval
                throw JPEGReadError.Unimplemented("restart intervals not implemented")
            
            case 0xfe, 0xe0 ..< 0xf0: // comment, or application data
                data = try readMarkerData(from: stream)

            default:
                return
            }

            defer
            {
                data.deallocate()
            }

            marker = try readNextMarker(from: stream)
        }
    }

    private mutating
    func updateQuantizationTables(from data:UnsafeRawBufferPointer) -> Void?
    {
        var i:Int = 0
        while (i < data.count)
        {
            let table:QuantizationTable,
                flags:UInt8 = data[i]
            // `i` gets incremented halfway through so it’s easier to just store
            // the `flags` byte
            switch flags & 0xf0
            {
            case 0x00:
                guard i + 64 + 1 <= data.count
                else
                {
                    return nil
                }

                table = .createQ8(data: data.baseAddress! + i + 1)
                i += 64 + 1

            case 0x10:
                guard i + 128 + 1 <= data.count
                else
                {
                    return nil
                }

                table = .createQ16(data: data.baseAddress! + i + 1)
                i += 128 + 1

            default:
                // quantization table has invalid precision
                return nil
            }
            
            print(table)
            
            switch flags & 0x0f
            {
            case 0:
                qtables.0 = table

            case 1:
                qtables.1 = table

            case 2:
                qtables.2 = table

            case 3:
                qtables.3 = table

            default:
                return nil
            }
        }

        return ()
    }

    private mutating
    func updateHuffmanTables(from data:UnsafeRawBufferPointer) -> Void?
    {
        guard var it:UnsafeRawPointer = data.baseAddress
        else
        {
            // only possible in an (invalid) malicious jpeg containing an empty
            // huffman marker
            return nil
        }

        let end:UnsafeRawPointer = it + data.count
        while (it < end)
        {
            guard it + 17 <= end
            else
            {
                // data buffer does not contain enough data
                return nil
            }

            let flags:UInt8 = it.load(as: UInt8.self)
            // `it` gets incremented halfway through so it’s easier to just store
            // the `flags` byte
            it += 1

            // huffman tables have variable length that can only be determined
            // by examining the first 17 bytes of each table which means checks
            // have to be done midway through the parsing
            let leafCounts:UnsafePointer<UInt8> = it.bindMemory(to: UInt8.self, capacity: 16)
            it += 16
            
            // count the number of expected leaves 
            let leaves:Int = (0 ..< 16).reduce(0){ $0 + Int(leafCounts[$1]) }

            guard it + leaves <= end
            else
            {
                // data buffer does not contain enough data
                return nil
            }

            let leafValues:UnsafePointer<UInt8> = it.bindMemory(to: UInt8.self, capacity: leaves)
            it += leaves 

            guard let table:HuffmanTable = .create(leafCounts: leafCounts, leafValues: leafValues)
            else 
            {
                return nil 
            }
            
            print(table)
            
            switch flags & 0x0f
            {
            case 0x00:
                dctables.0 = table
            
            case 0x01:
                dctables.1 = table

            case 0x02:
                dctables.2 = table

            case 0x03:
                dctables.3 = table
            
            case 0x10:
                actables.0 = table
            
            case 0x11:
                actables.1 = table

            case 0x12:
                actables.2 = table

            case 0x13:
                actables.3 = table

            default:
                // huffman table has invalid binding index
                return nil
            }
        }

        return ()
    }
}

struct Bitstream 
{
    let atoms:[UInt16]
    var position:Int = 0, 
        bit:UInt8    = 0
    
    init(_ data:[UInt8])
    {
        // convert byte array to big-endian UInt16 array 
        var atoms:[UInt16] = stride(from: 0, to: data.count - 1, by: 2).map
        {
            UInt16(data[$0]) << 8 | UInt16(data[$0 | 1])
        }
        
        if data.count & 1 != 0
        {
            atoms.append(UInt16(data[data.count - 1]) << 8 | 0x00ff)
        }
        
        // insert two more 0xffff atoms to serve as a barrier
        atoms.append(0xffff)
        atoms.append(0xffff)
        
        self.atoms = atoms
    }
    
    var front:UInt16?
    {
        // can optimize with two shifts and &>> ?
        let atom:UInt16 = self.atoms[self.position] << self.bit | self.atoms[self.position + 1] >> (16 - self.bit)
        
        guard atom != 0xffff 
        else 
        {
            return nil
        }
        
        return atom
    }
    
    mutating 
    func pop(_ bits:UInt8)
    {
        self.bit += bits 
        if self.bit > 15 
        {
            self.bit      &= 0x0f
            self.position += 1
        }
    }
}


struct _Spectra 
{
    struct ScanElement 
    {
        let offset:Int, 
            factor:Int, 
            dcTable:HuffmanTable, 
            acTable:HuffmanTable, 
            quantizationTable:QuantizationTable
    }
    
    struct Codebook 
    {
        let dcTable:HuffmanTable, 
            acTable:HuffmanTable, 
            quantizationTable:QuantizationTable
    }
    
    private 
    var storage:[Int16] = []
    private 
    let layout:[(end:Int, q:UInt8)]
    
    private 
    var stride:(Int, Int) 
    {
        return (self.layout[self.layout.count - 1].end << 6, 1 << 6)
    }
    
    subscript(group:Int, block:Int, k:Int) -> Int16
    {
        get 
        {
            return self.storage[group * self.stride.0 + block + self.stride.1 + k]
        }
        set(value) 
        {
            self.storage[group * self.stride.0 + block + self.stride.1 + k] = value
        }
    }
    
    init(components:[FrameHeader.Component])
    {
        var end:Int = 0
        self.layout = components.map 
        {
            end += Int($0.sampleFactors.x * $0.sampleFactors.y)
            return (end, $0.q)
        } 
    }
    
    static 
    func amplitude(count:UInt8, bitPattern:UInt16) -> Int16
    {
        assert(count > 0)
        
        let flip:UInt16 = bitPattern >> (UInt16.bitWidth - 1) ^ (1 as UInt16)
        
        // extract the most significant bit and shift it to the least significant position, 
        // and flip it, so that it will look like the sign bit of the result
        let sign:Int16  = Int16(bitPattern: flip << (Int16.bitWidth - 1)), 
            mask:Int16  = sign &>> (UInt8(UInt16.bitWidth) - 1 &- count)
        
        // if negative, we need to add 1 (per our two’s complement rule)
        return mask | Int16(bitPattern: bitPattern &>> (UInt8(UInt16.bitWidth) &- count) &+ flip)
    }

    mutating 
    func extend(to underestimatedCount:Int)
    {
        // unimplemented
    }

    mutating 
    func decodeDeep(_ bitstream:inout Bitstream, group:Int, offset:Int, band:Range<Int>, exponent:Int, codebook:Codebook) -> Void?
    {
        // unimplemented
        @inline(__always)
        func _decodeDeep(k:Int, table:HuffmanTable) -> Void?
        {
            guard let path:UInt16 = bitstream.front
            else 
            {
                return nil
            }
            
            let entry:HuffmanTable.Entry = table[path]
            bitstream.pop(entry.length)
            
            let bits:UInt8 = entry.value
            guard let tail:UInt16 = bitstream.front
            else 
            {
                return nil
            }
            bitstream.pop(bits)
            
            let amplitude:Int16 = _Spectra.amplitude(count: bits, bitPattern: tail)
            
            self[group, offset, k] |= amplitude << exponent
            return ()
        }
        
        if band.lowerBound == 0 
        {
            guard let _:Void = _decodeDeep(k: 0, table: codebook.dcTable)
            else 
            {
                return nil
            }
        }
        
        for _ in max(band.lowerBound, 1) ..< band.upperBound 
        {
            guard let _:Void = _decodeDeep(k: 0, table: codebook.acTable)
            else 
            {
                return nil
            }
        }
        
        return ()
    }
    
    mutating 
    func _updateSpectra(for components:[(offset:Int, factor:Int, codebook:Codebook)])
    {
        var group:Int = 0
        while true
        {
            self.extend(to: group)
            for (offset, factor, codebook):(Int, Int, Codebook) in components 
            {
                for i:Int in 0 ..< factor
                {
                    //self.decode(group: group, offset: offset + i, codebook: codebook)
                }
            }
            
            group += 1
        }
    }
}

func decodeEntropicSegment(from stream:UnsafeMutablePointer<FILE>, marker:inout UInt8) throws
{
    var data:[UInt8] = [],
        byte:UInt8   = try readUInt8(from: stream) // if not buffered, we could at least read in pairs
    while true
    {
        if byte == 0xff
        {
            // this is the only exit point from this function so we can just
            // reuse the `inout marker` variable
            marker = try readUInt8(from: stream)
            if marker != 0x00
            {
                while marker == 0xff
                {
                    marker = try readUInt8(from: stream)
                }

                
                return 
            }
        }

        data.append(byte)
        byte = try readUInt8(from: stream)
    }
}

func decode(path:String) throws
{
    guard let stream:UnsafeMutablePointer<FILE> = fopen(resolvePath(path), "rb")
    else
    {
        throw JPEGReadError.FileError(resolvePath(path))
    }
    defer
    {
        fclose(stream)
    }
    
    // the kaylor jpeg (a typical jpeg) is laid out like this 
    // 
    // {
    //     start of image, 
    //     {
    //         [
    //             quantization table definition ([0]), 
    //             quantization table definition ([1])
    //         ], 
    //         frame header, 
    //         [
    //             {
    //                 [
    //                     huffman table definition ([0]: DC), 
    //                     huffman table definition ([1]: DC)
    //                 ], 
    //                 scan header, 
    //                 [MCU, MCU, MCU, ...]
    //             }, 
    //             dnl segment (not present), 
    //             {
    //                 [
    //                     huffman table definition ([0]: AC)
    //                 ], 
    //                 scan header, 
    //                 [MCU, MCU, MCU, ...]
    //             }, 
    //             {
    //                 [
    //                     huffman table definition ([1]: AC)
    //                 ], 
    //                 scan header, 
    //                 [MCU, MCU, MCU, ...]
    //             }, 
    //             {
    //                 [
    //                     huffman table definition ([1]: AC)
    //                 ], 
    //                 scan header, 
    //                 [MCU, MCU, MCU, ...]
    //             }, 
    //             {
    //                 [
    //                     huffman table definition ([0]: AC)
    //                 ], 
    //                 scan header, 
    //                 [MCU, MCU, MCU, ...]
    //             }, 
    //             {
    //                 [
    //                     huffman table definition ([0]: AC)
    //                 ], 
    //                 scan header, 
    //                 [MCU, MCU, MCU, ...]
    //             }, 
    //             {
    //                 scan header, 
    //                 [MCU, MCU, MCU, ...]
    //             }, 
    //             {
    //                 [
    //                     huffman table definition ([1]: AC)
    //                 ], 
    //                 scan header, 
    //                 [MCU, MCU, MCU, ...]
    //             }, 
    //             {
    //                 [
    //                     huffman table definition ([1]: AC)
    //                 ], 
    //                 scan header, 
    //                 [MCU, MCU, MCU, ...]
    //             }
    //         ]
    //     }
    //     end of image
    // }
    
    // start of image marker
    guard try readNextMarker(from: stream) == 0xd8
    else
    {
        throw JPEGReadError.FiletypeError
    }

    var marker:UInt8 = try readNextMarker(from: stream)

    guard let _:JFIF = try .read(from: stream, marker: &marker)
    else
    {
        throw JPEGReadError.InvalidJFIFHeader
    }

    var context:Context = .init()
    
    try context.update(from: stream, marker: &marker)

    guard var frameHeader:FrameHeader = try .read(from: stream, marker: &marker)
    else
    {
        throw JPEGReadError.InvalidFrameHeader
    }
    
    print(frameHeader)

    var firstScan:Bool = true
    while marker != 0xd9 // end of image
    {
        try context.update(from: stream, marker: &marker)
        guard let scanHeader:ScanHeader = try .read(from: stream, marker: marker)
        else
        {
            throw JPEGReadError.InvalidScanHeader
        }
        
        print(scanHeader)

        try decodeEntropicSegment(from: stream, marker: &marker)

        if context.restartInterval > 0
        {
            while context.restart(marker: marker)
            {
                try decodeEntropicSegment(from: stream, marker: &marker)
            }
        }

        if firstScan
        {
            try frameHeader.updateHeight(from: stream, marker: &marker)
            firstScan = false
        }
    }
    // the while loop already scanned the EOI marker
    
    print() // space for testing progress bar
    print()
    print()
    print() 
}
