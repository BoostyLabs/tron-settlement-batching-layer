package dao.tron.tsol.service;

import dao.tron.tsol.model.TransferIntentRequest;
import org.springframework.stereotype.Service;

import java.util.ArrayList;
import java.util.List;

@Service
public class TransferIntentService {

    private final List<TransferIntentRequest> pending = new ArrayList<>();

    public synchronized void addIntent(TransferIntentRequest req) {
        pending.add(req);
    }

    public synchronized boolean isEmpty() {
        return pending.isEmpty();
    }

    public synchronized int getPendingCount() {
        return pending.size();
    }

    public synchronized long getOldestAgeSeconds() {
        if (pending.isEmpty()) return 0L;
        long oldestTs = pending.getFirst().getTimestamp();
        long now = System.currentTimeMillis() / 1000L;
        return now - oldestTs;
    }

    public synchronized List<TransferIntentRequest> drainUpTo(int max) {
        if (pending.isEmpty()) return List.of();
        int n = Math.min(max, pending.size());
        List<TransferIntentRequest> res = new ArrayList<>(pending.subList(0, n));
        pending.subList(0, n).clear();
        return res;
    }
}
