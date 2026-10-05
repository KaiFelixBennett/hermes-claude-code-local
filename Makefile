# Hermes Local Stack — Unified Entry Point
# Works on Linux, macOS, and WSL2

SHELL := /bin/bash
.PHONY: setup start hermes claude-bridge litellm stop status help clean

## Default target shows help
.DEFAULT_GOAL := help

## Colors for output
GREEN  := \033[0;32m
CYAN   := \033[0;36m
YELLOW := \033[1;33m
RED    := \033[0;31m
NC     := \033[0m

## Paths
REPO_DIR := $(shell pwd)
CONFIG   := $(REPO_DIR)/hermes_config.yaml
LLAMA_LOG := /tmp/llama-server.log
LITELLM_LOG := /tmp/hermes-litellm.log

## The official Hermes installer links hermes into ~/.local/bin, which a
## shell opened before setup does not have on PATH yet.
export PATH := $(HOME)/.local/bin:$(PATH)

## curl -f: llama-server answers 503 while the model is still loading,
## and that must not count as ready.
LLAMA_READY := curl -sf http://127.0.0.1:8080/v1/models > /dev/null 2>&1

##############################################################################
# Help
##############################################################################
help: ## Show this help
	@echo ""
	@echo -e "$(CYAN)Hermes Local Stack — Commands$(NC)"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-18s$(NC) %s\n", $$1, $$2}'
	@echo ""

##############################################################################
# Setup
##############################################################################
setup: ## Run the full one-command setup
	@if [ -f "$(REPO_DIR)/setup.sh" ]; then \
		bash $(REPO_DIR)/setup.sh; \
	else \
		echo "setup.sh not found. On Windows, use ./setup_hermes_local.ps1 instead."; \
	fi

##############################################################################
# Start Services
##############################################################################
start: llama hermes ## Start llama.cpp + Hermes (no Claude bridge)

hermes: check-llama ## Start Hermes Agent
	@echo -e "$(CYAN)[HERMES]$(NC) Starting Hermes Agent..."
	@hermes || { echo "Hermes not found. Run 'make setup' first."; exit 1; }

check-llama: ## Check if llama.cpp is running
	@$(LLAMA_READY) || { \
		echo -e "$(YELLOW)[WARN]$(NC) llama.cpp not reachable at port 8080"; \
		echo "     Starting llama.cpp first..."; \
		$(MAKE) llama; \
	}

llama: ## Start llama.cpp server
	@if $(LLAMA_READY); then \
		echo -e "$(GREEN)[OK]$(NC)    llama.cpp is already running"; \
	else \
		echo -e "$(CYAN)[LLAMA]$(NC) Starting llama.cpp server (log: $(LLAMA_LOG))..."; \
		bash $(REPO_DIR)/start_llamacpp.sh > $(LLAMA_LOG) 2>&1 & \
		echo $$! > /tmp/hermes-llama.pid; \
		$(MAKE) llama-wait; \
	fi

llama-wait: ## Wait for llama.cpp to be ready (a 27B model takes a while to load)
	@for i in $$(seq 1 150); do \
		if $(LLAMA_READY); then \
			echo -e "$(GREEN)[OK]$(NC)    llama.cpp is ready"; \
			break; \
		fi; \
		if [ -f /tmp/hermes-llama.pid ] && ! kill -0 $$(cat /tmp/hermes-llama.pid) 2>/dev/null; then \
			echo -e "$(RED)[ERROR]$(NC) llama.cpp exited. Last lines of $(LLAMA_LOG):"; \
			tail -n 15 $(LLAMA_LOG); \
			exit 1; \
		fi; \
		if [ $$i -eq 150 ]; then \
			echo -e "$(RED)[ERROR]$(NC) llama.cpp not ready after 5 minutes. Check $(LLAMA_LOG)"; \
			exit 1; \
		fi; \
		sleep 2; \
	done

claude-bridge: check-llama litellm hermes ## Start everything including Claude Code bridge

litellm: ## Start LiteLLM proxy for Claude Code bridge
	@if curl -s http://127.0.0.1:4000 > /dev/null 2>&1; then \
		echo -e "$(GREEN)[OK]$(NC)    LiteLLM is already running on port 4000"; \
	else \
		echo -e "$(CYAN)[LITELLM]$(NC) Starting LiteLLM proxy..."; \
		if command -v litellm > /dev/null 2>&1; then \
			litellm --config $(REPO_DIR)/litellm.proxy.yaml \
				--port 4000 \
				> $(LITELLM_LOG) 2>&1 & \
			echo $$! > /tmp/hermes-litellm.pid; \
		else \
			python3 -m pip install litellm; \
			litellm --config $(REPO_DIR)/litellm.proxy.yaml \
				--port 4000 \
				> $(LITELLM_LOG) 2>&1 & \
			echo $$! > /tmp/hermes-litellm.pid; \
		fi; \
		echo -e "$(GREEN)[OK]$(NC)    LiteLLM started"; \
	fi

##############################################################################
# Stop Services
##############################################################################
stop: stop-llama stop-litellm ## Stop all services

## pkill patterns match only the processes this Makefile starts, written as
## [l]itellm so the pattern does not match itself. A plain "litellm" also
## matched /tmp/hermes-litellm.pid in the recipe's own shell and killed it,
## and a plain "llama-server" stopped every llama-server of the user.

stop-llama: ## Stop llama.cpp
	@if [ -f /tmp/hermes-llama.pid ]; then \
		kill $$(cat /tmp/hermes-llama.pid) 2>/dev/null || true; \
		rm -f /tmp/hermes-llama.pid; \
		echo -e "$(GREEN)[OK]$(NC)    llama.cpp stopped"; \
	else \
		pkill -f "[l]lama-server .*--port 8080" 2>/dev/null || true; \
		echo -e "$(YELLOW)[WARN]$(NC) No llama.cpp PID file found, tried pkill"; \
	fi

stop-litellm: ## Stop LiteLLM
	@if [ -f /tmp/hermes-litellm.pid ]; then \
		kill $$(cat /tmp/hermes-litellm.pid) 2>/dev/null || true; \
		rm -f /tmp/hermes-litellm.pid; \
		echo -e "$(GREEN)[OK]$(NC)    LiteLLM stopped"; \
	else \
		pkill -f "[l]itellm --config" 2>/dev/null || true; \
		echo -e "$(YELLOW)[WARN]$(NC) No LiteLLM PID file found, tried pkill"; \
	fi

##############################################################################
# Status & Utilities
##############################################################################
status: ## Show service status
	@echo ""
	@echo -e "$(CYAN)Service Status$(NC)"
	@echo "─────────────"
	@echo -n "  llama.cpp:     "
	@if $(LLAMA_READY); then \
		echo -e "$(GREEN)running$(NC)"; \
	else \
		echo -e "$(YELLOW)not running$(NC)"; \
	fi
	@echo -n "  LiteLLM:       "
	@if curl -s http://127.0.0.1:4000 > /dev/null 2>&1; then \
		echo -e "$(GREEN)running$(NC)"; \
	else \
		echo -e "$(YELLOW)not running$(NC)"; \
	fi
	@echo -n "  Hermes:        "
	@if pgrep -f "hermes" > /dev/null 2>&1; then \
		echo -e "$(GREEN)running$(NC)"; \
	else \
		echo -e "$(YELLOW)not running$(NC)"; \
	fi
	@echo ""

clean: stop ## Clean up logs and temp files
	@rm -f $(LLAMA_LOG) $(LITELLM_LOG)
	@echo -e "$(GREEN)[OK]$(NC)    Cleaned up"
