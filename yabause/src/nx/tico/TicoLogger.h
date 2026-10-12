/// @file TicoLogger.h
/// @brief Tico file-based logger for Switch
#pragma once
#include <cstdarg>
#include <cstdio>
#include <string>
#include <unordered_map>

class Logger
{
public:
  enum class Level
  {
    DEBUG,
    INFO,
    WARNING,
    ERROR
  };
  enum Flags : uint32_t
  {
    None = 0,
    SwitchOnly = 1 << 0
  };

  static Logger &Instance()
  {
    static Logger instance;
    return instance;
  }

  void EnableCategory(const std::string &category, bool enabled = true)
  {
    m_categoryStates[category] = enabled;
  }

  bool IsCategoryEnabled(const std::string &category) const
  {
    auto it = m_categoryStates.find(category);
    if (it != m_categoryStates.end())
    {
      return it->second;
    }
    return true;
  }

  void Log(Level level, const char *category, uint32_t flags,
           const char *format, ...)
  {
#ifdef DISABLE_LOGGING
    return;
#endif
    if (flags & SwitchOnly)
    {
#ifndef __SWITCH__
      return;
#endif
    }

    if (!IsCategoryEnabled(category))
    {
      return;
    }

#ifdef __SWITCH__
    if (!m_file)
    {
      m_file = fopen("sdmc:/tico/debug/yabasanshiro.txt", "a");
    }
    if (!m_file)
      return;

    fprintf(m_file, "[%s][%s] ", LevelToString(level), category);

    va_list args;
    va_start(args, format);
    vfprintf(m_file, format, args);
    va_end(args);

    fprintf(m_file, "\n");
    fflush(m_file);
#else
    printf("[%s][%s] ", LevelToString(level), category);

    va_list args;
    va_start(args, format);
    vprintf(format, args);
    va_end(args);

    printf("\n");
#endif
  }

  void SetMinLevel(Level level) { m_minLevel = level; }

  bool ShouldLog(Level level) const
  {
#ifdef DISABLE_LOGGING
    return false;
#endif
    return static_cast<int>(level) >= static_cast<int>(m_minLevel);
  }

  ~Logger()
  {
#ifdef __SWITCH__
    if (m_file)
    {
      fclose(m_file);
    }
#endif
  }

private:
  Logger() : m_minLevel(Level::DEBUG)
  {
#ifdef __SWITCH__
    m_file = nullptr;
#endif
    m_categoryStates["EGL"] = true;
    m_categoryStates["OVERLAY"] = true;
    m_categoryStates["HOME"] = true;
    m_categoryStates["RENDER"] = false;
    m_categoryStates["INPUT"] = false;
  }

  const char *LevelToString(Level level) const
  {
    switch (level)
    {
    case Level::DEBUG:
      return "DEBUG";
    case Level::INFO:
      return "INFO";
    case Level::WARNING:
      return "WARN";
    case Level::ERROR:
      return "ERROR";
    default:
      return "?";
    }
  }

  std::unordered_map<std::string, bool> m_categoryStates;
  Level m_minLevel;

#ifdef __SWITCH__
  FILE *m_file;
#endif
};

// Convenience macros
#ifdef DISABLE_LOGGING
#define LOG_DEBUG(cat, ...) \
  do                        \
  {                         \
  } while (0)
#define LOG_INFO(cat, ...) \
  do                       \
  {                        \
  } while (0)
#define LOG_WARN(cat, ...) \
  do                       \
  {                        \
  } while (0)
#define LOG_ERROR(cat, ...) \
  do                        \
  {                         \
  } while (0)
#else
#define LOG_DEBUG(cat, ...)                                                                              \
  do                                                                                                     \
  {                                                                                                      \
    if (Logger::Instance().IsCategoryEnabled(cat) && Logger::Instance().ShouldLog(Logger::Level::DEBUG)) \
    {                                                                                                    \
      Logger::Instance().Log(Logger::Level::DEBUG, cat, Logger::None, __VA_ARGS__);                      \
    }                                                                                                    \
  } while (0)

#define LOG_INFO(cat, ...)                                                                              \
  do                                                                                                    \
  {                                                                                                     \
    if (Logger::Instance().IsCategoryEnabled(cat) && Logger::Instance().ShouldLog(Logger::Level::INFO)) \
    {                                                                                                   \
      Logger::Instance().Log(Logger::Level::INFO, cat, Logger::None, __VA_ARGS__);                      \
    }                                                                                                   \
  } while (0)

#define LOG_WARN(cat, ...)                                                                                 \
  do                                                                                                       \
  {                                                                                                        \
    if (Logger::Instance().IsCategoryEnabled(cat) && Logger::Instance().ShouldLog(Logger::Level::WARNING)) \
    {                                                                                                      \
      Logger::Instance().Log(Logger::Level::WARNING, cat, Logger::None, __VA_ARGS__);                      \
    }                                                                                                      \
  } while (0)

#define LOG_ERROR(cat, ...)                                                                              \
  do                                                                                                     \
  {                                                                                                      \
    if (Logger::Instance().IsCategoryEnabled(cat) && Logger::Instance().ShouldLog(Logger::Level::ERROR)) \
    {                                                                                                    \
      Logger::Instance().Log(Logger::Level::ERROR, cat, Logger::None, __VA_ARGS__);                      \
    }                                                                                                    \
  } while (0)
#endif
