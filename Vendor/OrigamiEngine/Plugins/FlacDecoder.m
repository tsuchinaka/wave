//
// FlacDecoder.m
//
// Copyright (c) 2012 ap4y (lod@pisem.net)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "FLAC/all.h"
#import "FlacDecoder.h"
#import <math.h>

#define SAMPLES_PER_WRITE 512
#define FLAC__MAX_SUPPORTED_CHANNELS 2
#define SAMPLE_blockBuffer_SIZE ((FLAC__MAX_BLOCK_SIZE + SAMPLES_PER_WRITE) * FLAC__MAX_SUPPORTED_CHANNELS * (24/8))

@interface FlacDecoder () {
    FLAC__StreamDecoder *decoder;
    void *blockBuffer;
    int blockBufferFrames;    

    int bitsPerSample;
    int channels;
    float frequency;
    long totalFrames;
    int bitrate;
}

@property (retain, nonatomic) NSMutableDictionary *metadata;
@property (retain, nonatomic) id<ORGMSource> source;
@property (assign, nonatomic) BOOL endOfStream;

- (FLAC__StreamDecoder *)decoder;
- (char *)blockBuffer;
- (int)blockBufferFrames;
- (void)setBlockBufferFrames:(int)frames;

@end

@implementation FlacDecoder
@synthesize source;
@synthesize endOfStream;

- (void)dealloc {
    [self close];
    [_metadata release];
    [source release];
    [super dealloc];
}

#pragma mark - ORGMDecoder
+ (NSArray *)fileTypes {
	return [NSArray arrayWithObjects:@"flac", nil];
}

- (NSDictionary *)properties {
	return [NSDictionary dictionaryWithObjectsAndKeys:
            [NSNumber numberWithInt:channels], @"channels",
            [NSNumber numberWithInt:bitsPerSample], @"bitsPerSample",
            [NSNumber numberWithInt:bitrate], @"bitrate",
            [NSNumber numberWithFloat:frequency], @"sampleRate",
            [NSNumber numberWithDouble:totalFrames], @"totalFrames",
            [NSNumber numberWithBool:[source seekable]], @"seekable",
            @"little",@"endian",
            nil];
}

- (NSMutableDictionary *)metadata {
    return _metadata;
}

- (int)readAudio:(void *)buffer frames:(UInt32)frames {
	int framesRead = 0;
	int bytesPerFrame = (bitsPerSample/8) * channels;
	while (framesRead < frames) {
		if (blockBufferFrames == 0) {
			if (FLAC__stream_decoder_get_state(decoder) == FLAC__STREAM_DECODER_END_OF_STREAM ||
                FLAC__stream_decoder_get_state(decoder) == FLAC__STREAM_DECODER_SEEK_ERROR) {
				break;
			}
            
			FLAC__stream_decoder_process_single(decoder);
		}
        
		int framesToRead = blockBufferFrames;
		if (blockBufferFrames > frames) {
			framesToRead = frames;
		}
        
		memcpy(((uint8_t *)buffer) + (framesRead * bytesPerFrame),
               (uint8_t *)blockBuffer, framesToRead * bytesPerFrame);
        
		frames -= framesToRead;
		framesRead += framesToRead;
		blockBufferFrames -= framesToRead;
		
		if (blockBufferFrames > 0) {
			memmove((uint8_t *)blockBuffer,
                    ((uint8_t *)blockBuffer) + (framesToRead * bytesPerFrame),
                    blockBufferFrames * bytesPerFrame);
		}
	}
	
	return framesRead;
}

- (BOOL)open:(id<ORGMSource>)s {
	[self setSource:s];
	
    self.metadata = [NSMutableDictionary dictionary];
	decoder = FLAC__stream_decoder_new();
	if (decoder == NULL) {
		return NO;
    }
        
    FLAC__stream_decoder_set_metadata_respond(decoder, FLAC__METADATA_TYPE_VORBIS_COMMENT);
    FLAC__stream_decoder_set_metadata_respond(decoder, FLAC__METADATA_TYPE_PICTURE);
    
	if (FLAC__stream_decoder_init_stream(decoder,
										 ReadCallback,
										 ([source seekable] ? SeekCallback : NULL),
										 ([source seekable] ? TellCallback : NULL),
										 ([source seekable] ? LengthCallback : NULL),
										 ([source seekable] ? EOFCallback : NULL),
										 WriteCallback,
										 MetadataCallback,
										 ErrorCallback,
										 self
										 ) != FLAC__STREAM_DECODER_INIT_STATUS_OK) {
		return NO;
	}
	    
	if (!FLAC__stream_decoder_process_until_end_of_metadata(decoder) ||
        FLAC__stream_decoder_get_state(decoder) != FLAC__STREAM_DECODER_SEARCH_FOR_FRAME_SYNC ||
        !isfinite(frequency) || frequency <= 0.0f || channels < 1 || channels > FLAC__MAX_SUPPORTED_CHANNELS ||
        bitsPerSample < 8 || bitsPerSample > 24 || (bitsPerSample % 8) != 0) {
        NSLog(@"FlacDecoder: invalid STREAMINFO/state=%d rate=%.2f channels=%d bits=%d",
              FLAC__stream_decoder_get_state(decoder), frequency, channels, bitsPerSample);
        FLAC__stream_decoder_finish(decoder);
        FLAC__stream_decoder_delete(decoder);
        decoder = NULL;
        return NO;
    }
	long encodedBytes = [source size];
	double duration = frequency > 0.0 ? (double)totalFrames / (double)frequency : 0.0;
	if (encodedBytes > 0 && duration > 0.0) {
		double averageBitrate = ((double)encodedBytes * 8.0) / duration;
		if (averageBitrate > 0.0 && isfinite(averageBitrate)) bitrate = (int)(averageBitrate + 0.5);
	}
	blockBuffer = malloc(SAMPLE_blockBuffer_SIZE);
    if (!blockBuffer) {
        [self close];
        return NO;
    }
    
	return YES;
}

- (long)seek:(long)sample {
	if (!decoder || sample < 0) return -1;
	if (!FLAC__stream_decoder_seek_absolute(decoder, (FLAC__uint64)sample)) return -1;
	self.endOfStream = NO;
	[self setBlockBufferFrames:0];
	return sample;
}

- (void)close {
	if (decoder) {
		FLAC__stream_decoder_finish(decoder);
		FLAC__stream_decoder_delete(decoder);
	}
	if (blockBuffer) {
		free(blockBuffer);
	}
	[source close];
    
	decoder = NULL;
	blockBuffer = NULL;
}

#pragma mark - private
- (char *)blockBuffer {
	return blockBuffer;
}

- (int)blockBufferFrames {
	return blockBufferFrames;
}

- (void)setBlockBufferFrames:(int)frames {
	blockBufferFrames = frames;
}

- (FLAC__StreamDecoder *)decoder {
	return decoder;
}

#pragma mark - flac callbacks
FLAC__StreamDecoderReadStatus ReadCallback(const FLAC__StreamDecoder *decoder,
                                           FLAC__byte blockBuffer[],
                                           size_t *bytes,
                                           void *client_data) {
	FlacDecoder *flacDecoder = (FlacDecoder *)client_data;
	*bytes = [[flacDecoder source] read:blockBuffer amount:*bytes];
    
    if(*bytes == 0) {
		[flacDecoder setEndOfStream:YES];
		return FLAC__STREAM_DECODER_READ_STATUS_END_OF_STREAM;
	}
	else {
		return FLAC__STREAM_DECODER_READ_STATUS_CONTINUE;
	}
}

FLAC__StreamDecoderSeekStatus SeekCallback(const FLAC__StreamDecoder *decoder,
                                           FLAC__uint64 absolute_byte_offset,
                                           void *client_data) {
	FlacDecoder *flacDecoder = (FlacDecoder *)client_data;
	
	if(![[flacDecoder source] seek:(long)absolute_byte_offset whence:SEEK_SET])
		return FLAC__STREAM_DECODER_SEEK_STATUS_ERROR;
	else
		return FLAC__STREAM_DECODER_SEEK_STATUS_OK;
}

FLAC__StreamDecoderTellStatus TellCallback(const FLAC__StreamDecoder *decoder,
                                           FLAC__uint64 *absolute_byte_offset,
                                           void *client_data) {
	FlacDecoder *flacDecoder = (FlacDecoder *)client_data;

	off_t pos;
	if((pos = [[flacDecoder source] tell]) < 0) {
		return FLAC__STREAM_DECODER_TELL_STATUS_ERROR;
	} else {
		*absolute_byte_offset = (FLAC__uint64)pos;
		return FLAC__STREAM_DECODER_TELL_STATUS_OK;
	}
}

FLAC__bool EOFCallback(const FLAC__StreamDecoder *decoder, void *client_data) {
	FlacDecoder *flacDecoder = (FlacDecoder *)client_data;
	return (FLAC__bool)[flacDecoder endOfStream];
}

FLAC__StreamDecoderLengthStatus LengthCallback(const FLAC__StreamDecoder *decoder,
                                               FLAC__uint64 *stream_length,
                                               void *client_data) {
	FlacDecoder *flacDecoder = (FlacDecoder *)client_data;
	
	if ([[flacDecoder source] seekable]) {
		long currentPos = [[flacDecoder source] tell];

		// Chunked HTTP streams have no END to measure until the download
		// completes (HTTPSource reports seek failure there). Report an
		// error rather than a bogus length — playback streams fine
		// without it, only length-based seeking is unavailable.
		if (![[flacDecoder source] seek:0 whence:SEEK_END]) {
			[[flacDecoder source] seek:currentPos whence:SEEK_SET];
			return FLAC__STREAM_DECODER_LENGTH_STATUS_ERROR;
		}
		*stream_length = [[flacDecoder source] tell];

		[[flacDecoder source] seek:currentPos whence:SEEK_SET];

		return FLAC__STREAM_DECODER_LENGTH_STATUS_OK;
	} else {
		*stream_length = 0;
		return FLAC__STREAM_DECODER_LENGTH_STATUS_ERROR;
	}
}

FLAC__StreamDecoderWriteStatus WriteCallback(const FLAC__StreamDecoder *decoder,
                                             const FLAC__Frame *frame,
                                             const FLAC__int32 * const sampleblockBuffer[],
                                             void *client_data) {
	FlacDecoder *flacDecoder = (FlacDecoder *)client_data;
	
	void *blockBuffer = [flacDecoder blockBuffer];

	int8_t  *alias8;
	int16_t *alias16;
	int32_t *alias32;
	int sample, channel;
	int32_t	audioSample;

    switch(frame->header.bits_per_sample) {
        case 8:
            // Interleave the audio (no need for byte swapping)
            alias8 = blockBuffer;
            for(sample = 0; sample < frame->header.blocksize; ++sample) {
                for(channel = 0; channel < frame->header.channels; ++channel) {
                    *alias8++ = (int8_t)sampleblockBuffer[channel][sample];
                }
            }

            break;

        case 16:
            // Interleave the audio in host (little-endian) byte order. The
            // previous big-endian output forced AudioConverter into a pure
            // byte-swap pass per block; little-endian matches the mixer
            // output exactly and lets waPCMTrack use its passthrough path.
            alias16 = blockBuffer;
            for(sample = 0; sample < frame->header.blocksize; ++sample) {
                for(channel = 0; channel < frame->header.channels; ++channel) {
                    *alias16++ = (int16_t)sampleblockBuffer[channel][sample];
                }
            }

            break;

        case 24:
            // Interleave the audio in little-endian byte order.
            alias8 = blockBuffer;
            for(sample = 0; sample < frame->header.blocksize; ++sample) {
                for(channel = 0; channel < frame->header.channels; ++channel) {
                    audioSample = sampleblockBuffer[channel][sample];
                    *alias8++   = (int8_t)audioSample;
                    *alias8++   = (int8_t)(audioSample >> 8);
                    *alias8++   = (int8_t)(audioSample >> 16);
                }
            }

            break;

        case 32:
            // Interleave the audio in host (little-endian) byte order.
            alias32 = blockBuffer;
            for(sample = 0; sample < frame->header.blocksize; ++sample) {
                for(channel = 0; channel < frame->header.channels; ++channel) {
                    *alias32++ = sampleblockBuffer[channel][sample];
                }
            }
            break;
        default:
            NSLog(@"Error, unsupported sample size.");
        }

	[flacDecoder setBlockBufferFrames:frame->header.blocksize];
	return FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE;
}

void MetadataCallback(const FLAC__StreamDecoder *decoder,
                      const FLAC__StreamMetadata *metadata,
                      void *client_data) {
    if (metadata->type == FLAC__METADATA_TYPE_VORBIS_COMMENT) {
        FlacDecoder *flacDecoder = (FlacDecoder *)client_data;
        FLAC__StreamMetadata_VorbisComment comment = metadata->data.vorbis_comment;
        FLAC__uint32 count = metadata->data.vorbis_comment.num_comments;
        for (int i = 0; i < count; i++) {
            NSString *commentValue = [NSString stringWithUTF8String:(const char*)comment.comments[i].entry];
            if (!commentValue.length) continue;
			NSRange range = [commentValue rangeOfString:@"="];
			if (range.location == NSNotFound || range.location == 0) continue;
            NSString *key = [commentValue substringWithRange:NSMakeRange(0, range.location)];
            NSString *value = [commentValue substringWithRange:NSMakeRange(range.location + 1,
                                                                           commentValue.length - range.location - 1)];
            [flacDecoder.metadata setObject:value forKey:[key lowercaseString]];
        }
    } else if (metadata->type == FLAC__METADATA_TYPE_PICTURE) {
        FlacDecoder *flacDecoder = (FlacDecoder *)client_data;
        FLAC__StreamMetadata_Picture picture = metadata->data.picture;
        NSData *picture_data = [NSData dataWithBytes:picture.data
                                              length:picture.data_length];
        [flacDecoder.metadata setObject:picture_data forKey:@"picture"];
    } else if (metadata->type == FLAC__METADATA_TYPE_STREAMINFO) {
        FlacDecoder *flacDecoder = (FlacDecoder *)client_data;

        flacDecoder->channels = metadata->data.stream_info.channels;
        flacDecoder->frequency = metadata->data.stream_info.sample_rate;
        flacDecoder->bitsPerSample = metadata->data.stream_info.bits_per_sample;
        
        flacDecoder->totalFrames = (long)metadata->data.stream_info.total_samples;
    }
}

void ErrorCallback(const FLAC__StreamDecoder *decoder,
                   FLAC__StreamDecoderErrorStatus status,
                   void *client_data) {
}

@end
