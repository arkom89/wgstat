#!/usr/bin/env python3
"""Телеграм-бот для показа статистики WireGuard через wgstat.sh."""
import logging
import os
import shlex
import sys
import subprocess
from typing import Optional

from telegram import Update
from telegram.constants import ParseMode
from telegram.ext import ApplicationBuilder, CommandHandler, ContextTypes
from telegram.helpers import escape_markdown


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
LOGGER = logging.getLogger("wgstat_bot")

WGSTAT_CMD = os.getenv("WGSTAT_CMD", "/usr/local/sbin/wgstat.sh")


def build_stats_command(peer_name: Optional[str]) -> list[str]:
    #cmd = [WGSTAT_CMD, "stats"]
    cmd = shlex.split(WGSTAT_CMD)
    cmd.append("stats")
    if peer_name:
        cmd.append(peer_name)
    return cmd


def collect_stats(peer_name: Optional[str]) -> str:
    cmd = build_stats_command(peer_name)
    env = os.environ.copy()
    LOGGER.debug("Executing command: %s", " ".join(shlex.quote(part) for part in cmd))
    try:
        result = subprocess.run(
            cmd,
            check=False,
            capture_output=True,
            text=True,
            env=env,
        )
    except FileNotFoundError as exc:
        LOGGER.error("wgstat script not found: %s", exc)
        return "wgstat.sh не найден. Укажи путь в переменной WGSTAT_CMD."

    stdout = (result.stdout or "").strip()
    stderr = (result.stderr or "").strip()

    if result.returncode != 0:
        LOGGER.error("wgstat returned %s: %s", result.returncode, stderr)
        if stderr:
            return f"Ошибка запуска wgstat (код {result.returncode}):\n{stderr}"
        return f"wgstat завершился с кодом {result.returncode} без вывода ошибок."

    if stdout:
        return stdout

    if stderr:
        LOGGER.warning("wgstat returned only stderr")
        return f"wgstat не вывел данные, stderr:\n{stderr}"

    return "wgstat не вернул данных. Проверь запущен ли интерфейс и есть ли пиры."


async def start_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    text = (
        "Я показываю статистику WireGuard. "
        "Введи /stats чтобы увидеть всех пиров или /stats <имя> для конкретного."
    )
    await update.message.reply_text(text)


async def id_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    user = update.effective_user
    if not user:
        await update.message.reply_text("Не удалось определить ID пользователя.")
        return

    await update.message.reply_text(f"Твой Telegram ID: {user.id}")


async def stats_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    admin_id = context.bot_data.get("admin_id")
    user = update.effective_user
    if admin_id is None:
        await update.message.reply_text("BOT_ADMIN_ID не установлен. Обратитесь к администратору.")
        return

    if not user or user.id != admin_id:
        LOGGER.warning("Unauthorized access attempt by %s", user.id if user else "unknown user")
        await update.message.reply_text("Доступ запрещен")
        return

    peer_name = context.args[0] if context.args else None
    output = collect_stats(peer_name)
    escaped = escape_markdown(output, version=2)
    message = f"```\n{escaped}\n```"
    await update.message.reply_text(message, parse_mode=ParseMode.MARKDOWN_V2)


async def help_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    await update.message.reply_text(
        "Команды:\n"
        " /stats [peer] — статистика по всем или одному пиру.\n"
        " /id — узнать свой Telegram ID.\n"
        " /start — краткая справка.\n"
        " /help — эта помощь."
    )


def require_token() -> str:
    token = os.getenv("BOT_TOKEN")
    if not token:
        LOGGER.error("BOT_TOKEN is not set")
        sys.exit("Установите BOT_TOKEN с токеном бота")
    return token


def require_admin_id() -> int:
    admin_id_raw = os.getenv("BOT_ADMIN_ID")
    if not admin_id_raw:
        LOGGER.error("BOT_ADMIN_ID is not set")
        sys.exit("Установите BOT_ADMIN_ID с ID администратора бота")

    try:
        return int(admin_id_raw)
    except ValueError:
        LOGGER.error("BOT_ADMIN_ID must be an integer, got %s", admin_id_raw)
        sys.exit("BOT_ADMIN_ID должен быть числом")


def main() -> None:
    token = require_token()
    admin_id = require_admin_id()
    application = ApplicationBuilder().token(token).build()

    application.bot_data["admin_id"] = admin_id

    application.add_handler(CommandHandler("start", start_command))
    application.add_handler(CommandHandler("help", help_command))
    application.add_handler(CommandHandler("id", id_command))
    application.add_handler(CommandHandler("stats", stats_command))

    LOGGER.info("Bot started. Listening for commands...")
    application.run_polling(allowed_updates=Update.ALL_TYPES)


if __name__ == "__main__":
    main()
