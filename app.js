import { useState, useEffect } from "react";

const App = () => {
  const [paymentStatus, setPaymentStatus] = useState(null);
  const [Pi, setPi] = useState(null);

  useEffect(() => {
    const loadPiSDK = async () => {
      try {
        const sdk = await import("https://cdn.jsdelivr.net/npm/@minepi/sdk/+esm");
        setPi(sdk.Pi);
      } catch (error) {
        console.error("Failed to load Pi SDK: ", error);
        setPaymentStatus("Error loading Pi SDK");
      }
    };
    loadPiSDK();
  }, []);

  const handlePayment = async () => {
    if (!Pi) {
      console.error("Pi SDK not loaded");
      setPaymentStatus("Pi SDK not loaded");
      return;
    }

    try {
      // Ensure Pi SDK is initialized properly
      Pi.init({ version: "2.0" });

      // Define payment parameters
      const paymentData = {
        amount: 1.0, // Payment amount in Pi
        memo: "Test Pi Payment", // Payment description
        metadata: { test: "Payment for Pi Node Setup" },
      };

      // Request Payment
      const payment = await Pi.createPayment(paymentData, {
        onReadyForServerApproval: async (paymentId) => {
          console.log("Payment ID: ", paymentId);
          setPaymentStatus("Waiting for approval...");
        },
        onReadyForServerCompletion: async (paymentId, txid) => {
          console.log("Transaction ID: ", txid);
          setPaymentStatus("Payment Complete!");
        },
        onCancel: (paymentId) => {
          console.log("Payment Cancelled", paymentId);
          setPaymentStatus("Payment Cancelled");
        },
        onError: (error) => {
          console.log("Payment Error", error);
          setPaymentStatus("Error in payment");
        },
      });

      if (!payment) {
        throw new Error("Payment request failed");
      }
    } catch (error) {
      console.error("Payment Error: ", error);
      setPaymentStatus("Error in payment");
    }
  };

  return (
    <div>
      <h1>Pi Payment System</h1>
      <p>Status: {paymentStatus || "Waiting for payment..."}</p>
      <button onClick={handlePayment} disabled={!Pi}>Pay with Pi</button>
    </div>
  );
};

export default App;
