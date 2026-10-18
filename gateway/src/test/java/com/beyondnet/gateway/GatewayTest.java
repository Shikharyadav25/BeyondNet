package com.beyondnet.gateway;

import static org.junit.jupiter.api.Assertions.*;

import java.nio.*;
import java.nio.file.*;
import java.util.*;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

class GatewayTest {
  @TempDir Path dir;

  @Test
  void dartCompatibleGoldenFrames() throws Exception {
    var f =
        com.beyondnet.campus.contract.SignedContent.JSON.readValue(
            Files.readAllBytes(Path.of("../contracts/vectors/indexed-frames.json")), Map.class);
    var expected = (List<String>) f.get("frames");
    var actual =
        IndexedFrames.encode(
            Base64.getDecoder().decode((String) f.get("message")),
            (Integer) f.get("tag"),
            (Integer) f.get("frame_bytes"));
    assertEquals(
        expected, actual.stream().map(x -> Base64.getEncoder().encodeToString(x)).toList());
  }

  @Test
  void fallbackAndLargeMtuRoundTripWithDuplicates() {
    for (int mtu : List.of(20, 128, 512)) {
      byte[] payload = new byte[12288];
      new Random(3).nextBytes(payload);
      var session = new IndexedFrames();
      byte[] complete = null;
      for (byte[] frame : IndexedFrames.encode(payload, 42, mtu)) {
        byte[] result = session.write(frame, 0, 1000);
        if (result != null) complete = result;
        assertNull(session.write(frame, 0, 1000));
      }
      assertArrayEquals(payload, complete);
      session.respond(new byte[80], mtu);
      assertArrayEquals(session.read(0), session.read(0));
      assertArrayEquals(
          Arrays.copyOfRange(session.read(0), 3, session.read(0).length), session.read(3));
      assertThrows(IllegalArgumentException.class, () -> session.read(513));
      assertThrows(IllegalArgumentException.class, () -> session.write(new byte[20], 1, 1000));
    }
  }

  @Test
  void cursorAndMalformedTransfers() {
    var session = new IndexedFrames();
    var frames = IndexedFrames.encode(new byte[40], 7, 20);
    assertThrows(IllegalArgumentException.class, () -> session.write(frames.get(1), 0, 1000));
    session.write(frames.getFirst(), 0, 1000);
    byte[] conflict = frames.getFirst().clone();
    conflict[7] = 1;
    assertThrows(IllegalArgumentException.class, () -> session.write(conflict, 0, 1000));
    for (int i = 1; i < frames.size(); i++) session.write(frames.get(i), 0, 1000);
    session.respond(new byte[40], 20);
    session.write(
        ByteBuffer.allocate(7).put((byte) 4).putInt(7).putShort((short) 1).array(), 0, 1000);
    assertArrayEquals(IndexedFrames.encode(new byte[40], 7, 20).get(1), session.read(0));
    assertThrows(
        IllegalArgumentException.class,
        () ->
            session.write(
                ByteBuffer.allocate(7).put((byte) 4).putInt(8).putShort((short) 0).array(),
                0,
                1000));
    // A partial transfer cannot resume after the idle deadline.
    var partial = new IndexedFrames();
    partial.write(frames.getFirst(), 0, 1000);
    assertThrows(IllegalArgumentException.class, () -> partial.write(frames.get(1), 0, 32000));
  }

  @Test
  void custodyPersistsAndConflictsAreRejected() throws Exception {
    Path path = dir.resolve("queue.db");
    try (var q = new DurableQueue(path, 3, 2)) {
      assertTrue(q.offer("id", "alice", "payment", new byte[] {1}, 600, 100));
      assertFalse(q.offer("id", "alice", "payment", new byte[] {1}, 600, 100));
      assertThrows(
          IllegalArgumentException.class,
          () -> q.offer("id", "alice", "payment", new byte[] {2}, 600, 100));
      assertThrows(
          IllegalArgumentException.class,
          () -> q.offer("id", "bob", "payment", new byte[] {1}, 600, 100));
    }
    try (var q = new DurableQueue(path, 3, 2)) {
      var item = q.next("payment", 100);
      assertEquals("id", item.id());
      q.retry(item, 100);
      assertNull(q.next("payment", 101));
      assertNotNull(q.next("payment", 102));
      // Expiry preserves the original packet for mailbox recovery.
      assertArrayEquals(new byte[] {1}, q.next("payment", 1000).payload());
      q.finish("id", new byte[] {9});
      assertNull(q.next("payment", 1000));
      assertArrayEquals(new byte[] {9}, q.result("id", "alice"));
      assertNull(q.result("id", "bob"));
    }
  }

  @Test
  void quotasReservePaymentSpace() throws Exception {
    try (var q = new DurableQueue(dir.resolve("quota.db"), 2, 1)) {
      q.offer("a", "alice", "background", new byte[] {1}, 200, 100);
      assertThrows(
          IllegalStateException.class,
          () -> q.offer("b", "alice", "background", new byte[] {1}, 200, 100));
      q.offer("b", "bob", "background", new byte[] {1}, 200, 100);
      assertThrows(
          IllegalStateException.class,
          () -> q.offer("c", "charlie", "background", new byte[] {1}, 200, 100));
      assertTrue(q.offer("p", "alice", "payment", new byte[] {1}, 200, 100));
    }
  }

  @Test
  void uplinkRejectsArbitraryDestinations() {
    for (String url :
        List.of(
            "http://bank.example",
            "https://bank.example/arbitrary",
            "https://user@bank.example",
            "https://bank.example?target=x"))
      assertThrows(IllegalArgumentException.class, () -> new BankUplink(url, "token"));
  }
}
