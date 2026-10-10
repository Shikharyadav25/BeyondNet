package com.beyondnet.bank;

public class BankException extends RuntimeException {
  public final int status;

  public BankException(int status, String message) {
    super(message);
    this.status = status;
  }
}
