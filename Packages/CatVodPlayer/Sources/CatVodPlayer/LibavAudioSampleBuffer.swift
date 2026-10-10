import AudioToolbox
import CoreMedia
import Foundation

/// 自研内核的**音频帧 → 显示样本**转换（M04P10）：一块 Float32 交错 PCM → `CMSampleBuffer`。
///
/// 与视频侧的 ``LibavSampleBuffer`` 同一套路：纯转换、可单测；
/// 音频渲染器（`AVSampleBufferAudioRenderer`）只吃 `CMSampleBuffer`。
enum LibavAudioSampleBuffer {
    /// 包一块 PCM。返回 nil = 建不出来（坏参数 / 底层失败）。
    ///
    /// - Parameter ownedPCM: `malloc` 出来的缓冲 —— **成功时所有权交给 block buffer**
    ///   （之后由它释放）；失败时本函数自己 `free`，调用方不用管。
    ///
    /// 格式固定 **Float32 交错**：`AVSampleBufferAudioRenderer` 接受它，
    /// 且交错数据一个 block buffer 就能装下（平面式要给每声道一个 block，复杂得多）。
    static func make(
        ownedPCM: UnsafeMutableRawPointer,
        frameCount: Int,
        sampleRate: Double,
        channels: Int,
        presentationSeconds: Double,
        durationSeconds: Double
    ) -> CMSampleBuffer? {
        guard frameCount > 0, sampleRate > 0, channels > 0 else {
            free(ownedPCM)
            return nil
        }
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else {
            free(ownedPCM)
            return nil
        }

        let byteCount = frameCount * 4 * channels
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: ownedPCM,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, // 内存归它释放（free）
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr, let blockBuffer else {
            // 走到这里说明 block buffer 没接走内存：自己收尾
            free(ownedPCM)
            return nil
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(seconds: durationSeconds, preferredTimescale: 1_000_000),
            presentationTimeStamp: CMTime(seconds: presentationSeconds, preferredTimescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = byteCount
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else {
            // 内存已经归 block buffer 管（它释放时会 free）：这里不能再 free
            return nil
        }
        return sampleBuffer
    }
}
