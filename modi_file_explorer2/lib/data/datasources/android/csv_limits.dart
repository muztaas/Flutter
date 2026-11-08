const int maxCsvFileSizeBytes = 1 << 30;
const int maxCsvRowBytes = 256 * 1024;
const int maxCsvCellCharacters = 65536;
const int csvIndexChunkBytes = 64 * 1024;
const int csvProgressBatchRows = 64;
