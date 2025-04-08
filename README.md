# Train Logistics System for Satisfactory (Ficsit-Network)

Этот проект реализует базовый функционал логистики поездов для игры **Satisfactory** с использованием мода **Ficsit-Network** и Lua.  
Он вдохновлён логистическими системами из **Factorio**, такими как **LTN** и **Cyber Syn**, и всё ещё находится в активной разработке.

> ⚠️ Код писался лично для себя, поэтому может иногда меняться, дорабатываться и не иметь полной документации.

## Возможности (на текущий момент)

- Регистрация станций (поставщик, получатель, депо)
- Отправка и получение статусов станций
- Назначение поездов на основе приоритетов и доступности
- Минимальные требования к участию: знание Lua и базовая настройка сетевых компонентов Ficsit-Network

## Как использовать

1. Установите мод [Ficsit-Network](https://ficsit.app/)
2. Настройте OpenComputers или аналог для запуска кода
3. Разместите клиентский и серверный код на соответствующих машинах
4. Настройте роли станций (requester, provider, depot)

## Сотрудничество

Если у вас есть предложения или вы знаете, как улучшить текущую реализацию — **пулл реквесты приветствуются**!  
Особенно, если вы хорошо знакомы с:

- Lua
- Модом Ficsit-Network
- Логистическими системами из Factorio (LTN, Cyber Syn)

## Цель проекта

Создать надёжную, гибкую и масштабируемую логистическую сеть поездов в духе Factorio LTN — но для Satisfactory.

---

_Проект разработан и поддерживается в свободное время для личного пользования, но открыт для идей и сообщества._

# Train Logistics System for Satisfactory (Ficsit-Network)

This project implements a basic train logistics system for **Satisfactory**, using the **Ficsit-Network** mod and Lua.  
It is inspired by logistics systems from **Factorio**, such as **LTN** and **Cyber Syn**, and is still under active development.

> ⚠️ This code was originally written for personal use, so it may change or be refactored from time to time and might lack full documentation.

## Current Features

- Station registration (provider, requester, depot)
- Status communication between stations and central server
- Train assignment based on priority and availability
- Minimal setup required: Lua knowledge and basic Ficsit-Network configuration

## How to Use

1. Install the [Ficsit-Network mod](https://ficsit.app/)
2. Set up OpenComputers or a compatible system to run the code
3. Deploy the client and server scripts on respective machines
4. Configure station roles (requester, provider, depot)

## Contributing

If you have suggestions or know how to improve the implementation — **pull requests are welcome**!  
Especially if you're experienced with:

- Lua scripting
- The Ficsit-Network mod
- Logistics systems from Factorio (LTN, Cyber Syn)

## Project Goal

The goal is to build a reliable, flexible, and scalable train logistics network in the spirit of Factorio’s LTN — but for Satisfactory.

---

_This is a personal project developed and maintained in free time, but open to contributions and ideas from the community._
