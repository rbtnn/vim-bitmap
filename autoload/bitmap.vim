
" http://www.kk.iij4u.or.jp/~kondo/bmp/

let s:os2_bitmap = 12
let s:windows_bitmap = 40

let s:size = 4

let s:file_header_size = [
        \   ['type', 2],
        \   ['size', 4],
        \   ['reserved1', 2],
        \   ['reserved2', 2],
        \   ['off_bits', 4],
        \ ]

let s:info_header_size = {
        \   'os2' : [
        \     ['size', s:size],
        \     ['width', 2],
        \     ['height', 2],
        \     ['planes', 2],
        \     ['bit_count', 2],
        \   ],
        \   'windows' : [
        \     ['size', s:size],
        \     ['width', 4],
        \     ['height', 4],
        \     ['planes', 2],
        \     ['bit_count', 2],
        \     ['copmression', 4],
        \     ['size_image', 4],
        \     ['x_pix_per_meter', 4],
        \     ['y_pix_per_meter', 4],
        \     ['clr_used', 4],
        \     ['cir_important', 4],
        \   ],
        \ }

function! s:bitmap_format_name(size) abort
    if a:size is s:os2_bitmap
        return 'os2'
    endif
    if a:size is s:windows_bitmap
        return 'windows'
    endif
endfunction

function! s:get_off_bits(size) abort
    let off_bits = 0
    for pair in s:file_header_size
        let off_bits += pair[1]
    endfor
    let bitmap_format_name = s:bitmap_format_name(a:size)
    for pair in s:info_header_size[bitmap_format_name]
        let off_bits += pair[1]
    endfor
    return off_bits
endfunction

function! s:slice(bs, offset, length) abort
    return [ a:bs[(a:offset):(a:offset + a:length - 1)], a:offset + a:length ]
endfunction

function! s:to_integer(bs) abort
    let sum = 0
    let n = 0
    for b in a:bs
        let sum += pow(256, n) * b
        let n += 1
    endfor
    return float2nr(sum)
endfunction

function! s:integer_to_bytes(n, bytes) abort
    if a:bytes is 0
        return []
    else
        return reverse(map(split(printf("%0" . (a:bytes * 2) . "X", a:n), '..\zs'), 'str2nr(v:val, 16)'))
    endif
endfunction

function! s:to_string(bs) abort
    let s = ''
    for b in a:bs
        let s .= nr2char(b)
    endfor
    return s
endfunction

function! s:file_header(bs) abort
    let dict = {}

    let offset = 0
    for pair in s:file_header_size
        let [value, offset] = s:slice(a:bs, offset, pair[1])
        let dict[pair[0]] = function(pair[0] is 'type' ? 's:to_string' : 's:to_integer')(value)
    endfor

    return [dict, offset]
endfunction

function! s:info_header(bs, offset) abort
    let [size, offset] = s:slice(a:bs, a:offset, s:size)
    let dict = { 'size' : s:to_integer(size) }
    let bitmap_format_name = s:bitmap_format_name(dict.size)
    for pair in s:info_header_size[bitmap_format_name]
        if pair[0] isnot 'size'
            let [value, offset] = s:slice(a:bs, offset, pair[1])
            let dict[pair[0]] = s:to_integer(value)
        endif
    endfor
    return [dict, offset]
endfunction

function! s:bit24_imagedata(xs, offset, info_header) abort
    let line_width = a:info_header.width * a:info_header.bit_count / 8
    let padding_size = (line_width % 4 is 0) ? 0 : (4 - line_width % 4)
    let offset = a:offset
    let data = []
    for h in range(1, a:info_header.height)
        let line_data = []
        for w in range(1, a:info_header.width)
            let [blue, offset] = s:slice(a:xs, offset, 1)
            let [green, offset] = s:slice(a:xs, offset, 1)
            let [red, offset] = s:slice(a:xs, offset, 1)
            let line_data += [blue + green + red]
        endfor
        let [_, offset] = s:slice(a:xs, offset, padding_size)
        let data += [line_data]
    endfor
    return [data, offset]
endfunction

function! s:bit32_imagedata(xs, offset, info_header) abort
    let offset = a:offset
    let data = []
    for h in range(1, a:info_header.height)
        let line_data = []
        for w in range(1, a:info_header.width)
            let [blue, offset] = s:slice(a:xs, offset, 1)
            let [green, offset] = s:slice(a:xs, offset, 1)
            let [red, offset] = s:slice(a:xs, offset, 1)
            let [reserved, offset] = s:slice(a:xs, offset, 1)
            let line_data += [blue + green + red + reserved]
        endfor
        let data += [line_data]
    endfor
    return [data, offset]
endfunction

function! bitmap#read(path, ...) abort
    let dict = {}
    let headeronly = 0 < a:0 ? a:1 : 0
    let bs = readfile(a:path, 'B')
    let [file_header, offset] = s:file_header(bs)
    if file_header.type is 'BM'
        let [info_header, offset] = s:info_header(bs, offset)
        if !headeronly
            if info_header.bit_count is 24
                let [data, offset] = s:bit24_imagedata(bs, offset, info_header)
                let dict['data'] = data
            elseif info_header.bit_count is 32
                let [data, offset] = s:bit32_imagedata(bs, offset, info_header)
                let dict['data'] = data
            else
                throw printf('[bitmap]Do not suport %d bit bitmap', info_header.bit_count)
            endif
        endif
        let dict['file_header'] = file_header
        let dict['info_header'] = info_header
    else
        throw '[bitmap]Not BMP File Format'
    endif
    return dict
endfunction

function! bitmap#write(data, path) abort
    let bit_count = len(a:data[0][0]) * 8
    let bitmap_format = s:windows_bitmap
    " let bitmap_format = s:os2_bitmap
    let bitmap_format_name = s:bitmap_format_name(bitmap_format)
    let width = len(get(a:data, 0, []))
    let height = len(a:data)
    let line_width = width * bit_count / 8
    let padding_size = (line_width % 4 is 0) ? 0 : (4 - line_width % 4)
    let off_bits = s:get_off_bits(bitmap_format)
    let size = off_bits + height * (line_width + padding_size)

    let xs = []

    " file header
    let vs = [0x4d42, size, 0, 0, off_bits,]
    for i in range(0, len(vs) - 1)
        let xs += s:integer_to_bytes(vs[i], s:file_header_size[i][1])
    endfor

    " info header
    if bitmap_format is s:os2_bitmap
        let vs = [bitmap_format, width, height, 1, bit_count,]
    endif
    if bitmap_format is s:windows_bitmap
        let vs = [bitmap_format, width, height, 1, bit_count, 0, (size - off_bits), 0, 0, 0, 0,]
    endif
    for i in range(0, len(vs) - 1)
        let xs += s:integer_to_bytes(vs[i], s:info_header_size[bitmap_format_name][i][1])
    endfor

    " data
    let data = []
    for h in range(0, height - 1)
        for w in range(0, width - 1)
            if bit_count is 24 || bit_count is 32
                " Blue
                let data += s:integer_to_bytes(a:data[h][w][0], 1)
                " Green
                let data += s:integer_to_bytes(a:data[h][w][1], 1)
                " Red
                let data += s:integer_to_bytes(a:data[h][w][2], 1)
            endif
            if bit_count is 32
                " Reserved
                let data += s:integer_to_bytes(0, 1)
            endif
        endfor
        if bit_count is 24
            let data += s:integer_to_bytes(0x00, padding_size)
        endif
    endfor
    let xs += data

    if 0 < len(xs)
        let bs = 0z00
        let bs[len(bs) - 1] = bs[len(bs) - 1] + xs[0]
        for x in xs[1:]
            let bs += 0z00
            let bs[len(bs) - 1] = bs[len(bs) - 1] + x
        endfor
        call writefile(bs, a:path)
    endif
endfunction

