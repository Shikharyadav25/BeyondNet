package com.beyondnet.campus;

import static com.beyondnet.campus.contract.SignedContent.*;

import java.time.Instant;
import java.util.*;
import org.springframework.http.ResponseEntity;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/campus/v1")
public class CampusController {
  private final JdbcTemplate db;
  private final Publisher publisher;

  public CampusController(JdbcTemplate db, Publisher publisher) {
    this.db = db;
    this.publisher = publisher;
  }

  long now() {
    return Instant.now().getEpochSecond();
  }

  @GetMapping("/capabilities")
  public Object capabilities() {
    long time = now();
    return publisher.sign(
        Map.of(
            "v",
            1,
            "kind",
            "capabilities",
            "created_at",
            time,
            "expires_at",
            time + 60,
            "campus_backend_reachable",
            true,
            "public_cache_available",
            true,
            "messaging",
            false,
            "publisher_key",
            publisher.publicKey,
            "search_query_bytes",
            MAX_QUERY));
  }

  @PostMapping("/search")
  public Object search(@RequestBody Map<String, Object> request) {
    if (!request.keySet().equals(Set.of("request_id", "query", "page")))
      throw new IllegalArgumentException("Unexpected search fields");
    String id = UUID.fromString((String) request.get("request_id")).toString();
    String q = query((String) request.get("query"));
    long page = number(request, "page");
    if (page < 0 || page > 1000) throw new IllegalArgumentException("Invalid page");
    var results =
        db.queryForList(
            "SELECT id,title,body,source,updated_at,expires_at FROM campus_records WHERE"
                + " expires_at>? AND search_vector @@ plainto_tsquery('simple',?) ORDER BY"
                + " ts_rank(search_vector,plainto_tsquery('simple',?)) DESC,id LIMIT 4 OFFSET ?",
            now(),
            q,
            q,
            page * 3);
    boolean more = results.size() > 3;
    if (more) results = new ArrayList<>(results.subList(0, 3));
    long time = now();
    var body = new LinkedHashMap<String, Object>();
    body.put("v", 1);
    body.put("kind", "search_result");
    body.put("request_id", id);
    body.put("query", q);
    body.put("page", page);
    body.put("created_at", time);
    body.put("expires_at", time + 60);
    body.put("source", "campus_backend");
    body.put("results", results);
    body.put("has_more", more);
    var signed = publisher.sign(body);
    if (canonical(signed).length > MAX_RESPONSE)
      throw new IllegalStateException("Published records exceed response budget");
    return signed;
  }

  @GetMapping("/cache")
  public Object cache() {
    long time = now();
    var records =
        db.queryForList(
            "SELECT id,title,body,source,updated_at,expires_at FROM campus_records WHERE"
                + " expires_at>? ORDER BY id LIMIT 50",
            time);
    return publisher.sign(
        Map.of(
            "v",
            1,
            "kind",
            "public_cache",
            "created_at",
            time,
            "expires_at",
            time + 86400,
            "records",
            records));
  }

  @ExceptionHandler({
    IllegalArgumentException.class,
    ClassCastException.class,
    NullPointerException.class
  })
  ResponseEntity<?> invalid(Exception e) {
    return ResponseEntity.badRequest().body(Map.of("detail", "Invalid campus request"));
  }
}
