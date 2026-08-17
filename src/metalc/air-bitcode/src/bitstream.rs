//! Minimal LLVM bitstream writer (Metal AIR / LLVM 14–compatible subset).

#[derive(Debug)]
struct BlockFrame {
    prev_code_size: u32,
    /// Byte index of the 4-byte little-endian block length placeholder (word-aligned).
    size_word_byte_index: usize,
}

pub struct BitstreamWriter {
    buf: Vec<u8>,
    cur_bit: u32, // 0..31 within current unfinished word
    cur_word: u32,
    cur_code_size: u32,
    block_stack: Vec<BlockFrame>,
}

impl Default for BitstreamWriter {
    fn default() -> Self {
        Self::new()
    }
}

impl BitstreamWriter {
    pub fn new() -> Self {
        Self {
            buf: Vec::new(),
            cur_bit: 0,
            cur_word: 0,
            cur_code_size: 2, // default until first subblock
            block_stack: Vec::new(),
        }
    }

    pub fn into_bytes(mut self) -> Vec<u8> {
        self.flush_to_word();
        self.buf
    }

    pub fn emit(&mut self, val: u32, num_bits: u32) {
        assert!(num_bits <= 32);
        if num_bits == 0 {
            return;
        }
        let mask = if num_bits == 32 {
            u32::MAX
        } else {
            (1u32 << num_bits) - 1
        };
        let v = val & mask;
        self.cur_word |= v << self.cur_bit;
        if self.cur_bit + num_bits >= 32 {
            self.buf.extend_from_slice(&self.cur_word.to_le_bytes());
            let leftover = 32 - self.cur_bit;
            self.cur_bit = num_bits - leftover;
            self.cur_word = if leftover < 32 { v >> leftover } else { 0 };
        } else {
            self.cur_bit += num_bits;
        }
    }

    pub fn emit_vbr(&mut self, mut val: u64, num_bits: u32) {
        // LLVM VBR: low (n-1) bits data, high bit continues.
        assert!((2..=32).contains(&num_bits));
        let data_bits = num_bits - 1;
        loop {
            let chunk = (val as u32) & ((1u32 << data_bits) - 1);
            val >>= data_bits;
            if val == 0 {
                self.emit(chunk, num_bits);
                break;
            }
            self.emit(chunk | (1u32 << data_bits), num_bits);
        }
    }

    fn emit_code(&mut self, code: u32) {
        self.emit(code, self.cur_code_size);
    }

    pub fn flush_to_word(&mut self) {
        if self.cur_bit != 0 {
            self.buf.extend_from_slice(&self.cur_word.to_le_bytes());
            self.cur_bit = 0;
            self.cur_word = 0;
        }
    }

    pub fn enter_subblock(&mut self, block_id: u32, code_len: u32) {
        self.emit_code(1); // ENTER_SUBBLOCK
        self.emit_vbr(block_id as u64, 8);
        self.emit_vbr(code_len as u64, 4);
        self.flush_to_word();
        let size_word_byte_index = self.buf.len();
        self.emit(0, 32); // placeholder blocklen in 32-bit words
        self.block_stack.push(BlockFrame {
            prev_code_size: self.cur_code_size,
            size_word_byte_index,
        });
        self.cur_code_size = code_len;
    }

    pub fn exit_block(&mut self) {
        self.emit_code(0); // END_BLOCK
        self.flush_to_word();
        let frame = self.block_stack.pop().expect("exit_block without enter");
        let block_size_words = ((self.buf.len() - frame.size_word_byte_index) / 4) as u32 - 1;
        self.buf[frame.size_word_byte_index..frame.size_word_byte_index + 4]
            .copy_from_slice(&block_size_words.to_le_bytes());
        self.cur_code_size = frame.prev_code_size;
    }

    /// Emit an unabbreviated record: [UNABBREV_RECORD, code, #ops, ops...]
    pub fn emit_record(&mut self, code: u32, ops: &[u64]) {
        self.emit_code(3); // UNABBREV_RECORD
        self.emit_vbr(code as u64, 6);
        self.emit_vbr(ops.len() as u64, 6);
        for &op in ops {
            self.emit_vbr(op, 6);
        }
    }

    pub fn emit_string_record(&mut self, code: u32, s: &str) {
        let ops: Vec<u64> = s.bytes().map(|b| b as u64).collect();
        self.emit_record(code, &ops);
    }
}
