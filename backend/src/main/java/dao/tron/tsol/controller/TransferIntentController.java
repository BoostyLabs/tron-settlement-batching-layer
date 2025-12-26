package dao.tron.tsol.controller;

import dao.tron.tsol.model.TransferIntentRequest;
import dao.tron.tsol.service.TransferIntentService;
import jakarta.validation.Valid;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/intents")
public class TransferIntentController {

    private final TransferIntentService intentService;

    public TransferIntentController(TransferIntentService intentService) {
        this.intentService = intentService;
    }

    @PostMapping
    public ResponseEntity<Void> submitIntent(@Valid @RequestBody TransferIntentRequest req) {
        intentService.addIntent(req);
        return ResponseEntity.accepted().build();
    }
}
