package com.beyondnet.bank;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class BankApplication {
  public static void main(String[] args) throws Exception {
    if (java.util.Arrays.asList(args).contains("--migration-only")) {
      try (BankDatabase db = new BankDatabase()) {
        BankService bank = new BankService(db);
        System.out.println(
            "PostgreSQL bank ready. Accounts: "
                + db.read(c -> BankDatabase.scalar(c, "SELECT COUNT(*) FROM accounts")));
      }
      return;
    }
    SpringApplication.run(BankApplication.class, args);
  }
}
