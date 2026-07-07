package main

import (
	"context"
	"database/sql"
	"fmt"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
)

// PGStore persists the assistant's conversations and customer context to Postgres.
// It is optional: the bridge only uses it when DATABASE_URL is set. This gives a
// durable, remotely-accessible store (e.g. for deployment) alongside the local
// SQLite message log.
type PGStore struct {
	db *sql.DB
}

// NewPGStore opens a connection pool to Postgres and verifies connectivity.
func NewPGStore(url string) (*PGStore, error) {
	db, err := sql.Open("pgx", url)
	if err != nil {
		return nil, fmt.Errorf("open postgres: %w", err)
	}

	db.SetMaxOpenConns(10)
	db.SetMaxIdleConns(5)
	db.SetConnMaxLifetime(time.Hour)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := db.PingContext(ctx); err != nil {
		db.Close()
		return nil, fmt.Errorf("ping postgres: %w", err)
	}

	return &PGStore{db: db}, nil
}

// Close releases the connection pool.
func (p *PGStore) Close() error {
	if p == nil || p.db == nil {
		return nil
	}
	return p.db.Close()
}

// UpsertCustomer ensures a customer row exists for the chat and bumps its
// last_contact_time. It never overwrites existing profile fields with blanks.
func (p *PGStore) UpsertCustomer(chatJID, phone, name string) error {
	if p == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := p.db.ExecContext(ctx, `
		INSERT INTO customers (chat_jid, phone_number, name, last_contact_time, updated_at)
		VALUES ($1, NULLIF($2, ''), NULLIF($3, ''), now(), now())
		ON CONFLICT (chat_jid) DO UPDATE SET
			phone_number      = COALESCE(customers.phone_number, EXCLUDED.phone_number),
			name              = COALESCE(customers.name, EXCLUDED.name),
			last_contact_time = now(),
			updated_at        = now()
	`, chatJID, phone, name)
	return err
}

// SaveMessage appends one message (role = "customer" or "assistant") to the
// conversation log.
func (p *PGStore) SaveMessage(chatJID, role, content, waMessageID string) error {
	if p == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := p.db.ExecContext(ctx, `
		INSERT INTO conversations (chat_jid, role, content, wa_message_id)
		VALUES ($1, $2, $3, NULLIF($4, ''))
	`, chatJID, role, content, waMessageID)
	return err
}
