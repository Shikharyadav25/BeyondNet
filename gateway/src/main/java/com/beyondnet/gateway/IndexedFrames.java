package com.beyondnet.gateway;

import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.util.*;

/** Byte-compatible with mobile/lib/ble_frames.dart. One instance per connected peer. */
public final class IndexedFrames {
  public static final int LIMIT = 12288, HEADER = 7;
  private Integer transfer;
  private final List<byte[]> parts = new ArrayList<>();
  private final ByteArrayOutputStream data = new ByteArrayOutputStream();
  private boolean complete;
  private long touched;
  private List<byte[]> response;
  private int selected;

  public static List<byte[]> encode(byte[] bytes, int tag, int frameBytes) {
    if (bytes.length == 0 || bytes.length > LIMIT || frameBytes < 20 || frameBytes > 512)
      throw new IllegalArgumentException("Invalid message");
    var frames = new ArrayList<byte[]>();
    int payload = frameBytes - HEADER;
    for (int offset = 0, index = 0; offset < bytes.length; offset += payload, index++) {
      int length = Math.min(payload, bytes.length - offset);
      var frame =
          ByteBuffer.allocate(HEADER + length)
              .put((byte) ((offset == 0 ? 1 : 0) | (offset + length == bytes.length ? 2 : 0)))
              .putInt(tag)
              .putShort((short) index);
      frame.put(bytes, offset, length);
      frames.add(frame.array());
    }
    return frames;
  }

  public synchronized byte[] write(byte[] frame, int offset, long now) {
    if (offset != 0) throw new IllegalArgumentException("ATT write offset must be zero");
    if (now - touched > 30_000) {
      transfer = null;
      parts.clear();
      data.reset();
      complete = false;
      response = null;
      selected = 0;
    }
    touched = now;
    if (frame.length == HEADER && frame[0] == 4) {
      var buffer = ByteBuffer.wrap(frame);
      buffer.get();
      int tag = buffer.getInt(), index = Short.toUnsignedInt(buffer.getShort());
      if (transfer == null || transfer != tag)
        throw new IllegalArgumentException("Invalid response cursor");
      selected = index;
      return null;
    }
    if (frame.length <= HEADER || frame.length > 512 || frame[0] < 0 || frame[0] > 3)
      throw new IllegalArgumentException("Invalid frame");
    var buffer = ByteBuffer.wrap(frame);
    int flags = buffer.get();
    int tag = buffer.getInt(), index = Short.toUnsignedInt(buffer.getShort());
    boolean start = (flags & 1) != 0;
    if (transfer == null || transfer != tag) {
      if (!start || index != 0) throw new IllegalArgumentException("Missing start");
      transfer = tag;
      parts.clear();
      data.reset();
      complete = false;
      response = null;
      selected = 0;
    }
    if (start != (index == 0)) throw new IllegalArgumentException("Invalid start");
    if (index < parts.size()) {
      if (!Arrays.equals(parts.get(index), frame))
        throw new IllegalArgumentException("Conflicting retransmission");
      return null;
    }
    if (complete || index != parts.size()) throw new IllegalArgumentException("Reordered frame");
    if (data.size() + frame.length - HEADER > LIMIT)
      throw new IllegalArgumentException("Message too large");
    parts.add(frame.clone());
    data.write(frame, HEADER, frame.length - HEADER);
    if ((flags & 2) != 0) {
      complete = true;
      return data.toByteArray();
    }
    return null;
  }

  public synchronized void respond(byte[] bytes, int frameBytes) {
    if (!complete) throw new IllegalStateException("Incomplete request");
    response = encode(bytes, transfer, frameBytes);
    selected = 0;
  }

  public synchronized byte[] read(int offset) {
    byte[] frame;
    if (response == null) frame = new byte[] {0};
    else {
      if (selected >= response.size()) throw new IllegalArgumentException("Cursor out of range");
      frame = response.get(selected);
    }
    if (offset < 0 || offset > frame.length)
      throw new IllegalArgumentException("Invalid ATT read offset");
    return Arrays.copyOfRange(frame, offset, frame.length);
  }
}
