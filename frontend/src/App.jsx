import { useCallback, useEffect, useMemo, useState } from "react";

const TOKEN_KEY = "lms_access_token";

async function request(path, { token, ...options } = {}) {
  const response = await fetch(path, {
    ...options,
    headers: {
      "Content-Type": "application/json",
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...options.headers,
    },
  });
  const body = response.status === 204 ? null : await response.json().catch(() => null);
  if (!response.ok) {
    throw new Error(body?.detail || `HTTP ${response.status}`);
  }
  return body;
}

function AuthScreen({ onAuthenticated }) {
  const [mode, setMode] = useState("login");
  const [username, setUsername] = useState("admin");
  const [password, setPassword] = useState("admin12345");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");

  async function submit(event) {
    event.preventDefault();
    setBusy(true);
    setMessage("");
    try {
      if (mode === "register") {
        await request("/api/auth/register", {
          method: "POST",
          body: JSON.stringify({ username, password }),
        });
        setMode("login");
        setMessage("Обліковий запис створено. Тепер увійдіть.");
      } else {
        const data = await request("/api/auth/login", {
          method: "POST",
          body: JSON.stringify({ username, password }),
        });
        onAuthenticated(data.access_token);
      }
    } catch (error) {
      setMessage(error.message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <main className="auth-shell">
      <section className="brand-panel">
        <div className="brand-mark">CF</div>
        <p className="eyebrow">Observability-ready LMS</p>
        <h1>Навчання, яке видно наскрізь.</h1>
        <p className="brand-copy">
          Каталог курсів, записи студентів і повний шлях кожного запиту — від
          браузера до події RabbitMQ.
        </p>
        <div className="signal-row">
          <span>Metrics</span><i />
          <span>Logs</span><i />
          <span>Traces</span>
        </div>
      </section>

      <section className="auth-panel">
        <div className="auth-card">
          <p className="eyebrow">CourseFlow</p>
          <h2>{mode === "login" ? "З поверненням" : "Новий студент"}</h2>
          <p className="muted">
            {mode === "login"
              ? "Увійдіть, щоб побачити доступні курси."
              : "Створіть обліковий запис для навчання."}
          </p>
          <form onSubmit={submit}>
            <label>
              Ім’я користувача
              <input
                value={username}
                onChange={(event) => setUsername(event.target.value)}
                minLength={3}
                autoComplete="username"
                required
              />
            </label>
            <label>
              Пароль
              <input
                value={password}
                onChange={(event) => setPassword(event.target.value)}
                type="password"
                minLength={8}
                autoComplete={mode === "login" ? "current-password" : "new-password"}
                required
              />
            </label>
            {message && <p className="form-message">{message}</p>}
            <button className="primary-button" disabled={busy}>
              {busy ? "Зачекайте…" : mode === "login" ? "Увійти" : "Зареєструватися"}
            </button>
          </form>
          <button
            className="text-button"
            type="button"
            onClick={() => {
              setMode(mode === "login" ? "register" : "login");
              setMessage("");
              if (mode === "login") {
                setUsername("");
                setPassword("");
              }
            }}
          >
            {mode === "login" ? "Створити новий акаунт" : "У мене вже є акаунт"}
          </button>
          {mode === "login" && (
            <p className="demo-hint">Demo admin: admin / admin12345</p>
          )}
        </div>
      </section>
    </main>
  );
}

function CourseCard({ course, enrollment, onEnroll, onProgress, busy }) {
  return (
    <article className="course-card">
      <div className="course-topline">
        <span className="course-tag">{course.duration_hours} год</span>
        <span className="course-id">#{String(course.id).padStart(2, "0")}</span>
      </div>
      <h3>{course.title}</h3>
      <p>{course.description}</p>
      <div className="course-footer">
        <div>
          <span className="caption">Викладач</span>
          <strong>{course.instructor}</strong>
        </div>
        {!enrollment ? (
          <button onClick={() => onEnroll(course.id)} disabled={busy}>
            Записатися
          </button>
        ) : (
          <span className="enrolled-badge">Записано</span>
        )}
      </div>
      {enrollment && (
        <div className="progress-block">
          <div className="progress-label">
            <span>Прогрес</span><strong>{enrollment.progress_percent}%</strong>
          </div>
          <div className="progress-track">
            <span style={{ width: `${enrollment.progress_percent}%` }} />
          </div>
          {enrollment.progress_percent < 100 && (
            <button
              className="progress-button"
              onClick={() => onProgress(enrollment)}
              disabled={busy}
            >
              +25% прогресу
            </button>
          )}
        </div>
      )}
    </article>
  );
}

function Dashboard({ token, onLogout }) {
  const [user, setUser] = useState(null);
  const [courses, setCourses] = useState([]);
  const [enrollments, setEnrollments] = useState([]);
  const [search, setSearch] = useState("");
  const [error, setError] = useState("");
  const [busyId, setBusyId] = useState(null);

  const load = useCallback(async () => {
    try {
      const [me, courseData, enrollmentData] = await Promise.all([
        request("/api/auth/me", { token }),
        request("/api/courses", { token }),
        request("/api/enrollments", { token }),
      ]);
      setUser(me);
      setCourses(courseData.items);
      setEnrollments(enrollmentData);
      setError("");
    } catch (loadError) {
      if (/401|Authentication|token/i.test(loadError.message)) onLogout();
      else setError(loadError.message);
    }
  }, [token, onLogout]);

  useEffect(() => {
    load();
  }, [load]);

  const enrollmentByCourse = useMemo(
    () => Object.fromEntries(enrollments.map((item) => [item.course_id, item])),
    [enrollments],
  );
  const filteredCourses = courses.filter((course) =>
    `${course.title} ${course.description} ${course.instructor}`
      .toLowerCase()
      .includes(search.toLowerCase()),
  );

  async function enroll(courseId) {
    setBusyId(courseId);
    setError("");
    try {
      const enrollment = await request("/api/enrollments", {
        token,
        method: "POST",
        body: JSON.stringify({ course_id: courseId }),
      });
      setEnrollments((items) => [enrollment, ...items]);
    } catch (actionError) {
      setError(actionError.message);
    } finally {
      setBusyId(null);
    }
  }

  async function advanceProgress(enrollment) {
    setBusyId(enrollment.course_id);
    setError("");
    try {
      const updated = await request(`/api/enrollments/${enrollment.id}/progress`, {
        token,
        method: "PATCH",
        body: JSON.stringify({
          progress_percent: Math.min(100, enrollment.progress_percent + 25),
        }),
      });
      setEnrollments((items) =>
        items.map((item) => (item.id === updated.id ? updated : item)),
      );
    } catch (actionError) {
      setError(actionError.message);
    } finally {
      setBusyId(null);
    }
  }

  return (
    <div className="app-shell">
      <header>
        <a className="wordmark" href="#top"><span>CF</span> CourseFlow</a>
        <nav>
          <a href="#catalog">Каталог</a>
          <a href="http://localhost:3000/d/lms-overview/lms-overview" target="_blank">
            Grafana ↗
          </a>
        </nav>
        <div className="profile">
          <div><strong>{user?.username || "…"}</strong><span>{user?.role}</span></div>
          <button className="icon-button" onClick={onLogout} title="Вийти">↪</button>
        </div>
      </header>

      <main id="top">
        <section className="hero">
          <p className="eyebrow">Освітня платформа</p>
          <h1>Оберіть наступну<br /><em>точку росту.</em></h1>
          <p>Практичні курси з розробки, баз даних та спостережуваності систем.</p>
          <div className="hero-stats">
            <div><strong>{courses.length}</strong><span>курсів</span></div>
            <div><strong>{enrollments.length}</strong><span>моїх записів</span></div>
            <div><strong>3</strong><span>сигнали системи</span></div>
          </div>
        </section>

        <section className="catalog" id="catalog">
          <div className="catalog-heading">
            <div><p className="eyebrow">Каталог</p><h2>Усі курси</h2></div>
            <input
              className="search"
              value={search}
              onChange={(event) => setSearch(event.target.value)}
              placeholder="Пошук курсу…"
              aria-label="Пошук курсу"
            />
          </div>
          {error && <div className="error-banner">{error}</div>}
          <div className="course-grid">
            {filteredCourses.map((course) => (
              <CourseCard
                key={course.id}
                course={course}
                enrollment={enrollmentByCourse[course.id]}
                onEnroll={enroll}
                onProgress={advanceProgress}
                busy={busyId === course.id}
              />
            ))}
          </div>
        </section>
      </main>
      <footer>
        <span>CourseFlow LMS skeleton</span>
        <span>FastAPI · PostgreSQL · RabbitMQ · Grafana</span>
      </footer>
    </div>
  );
}

export default function App() {
  const [token, setToken] = useState(() => localStorage.getItem(TOKEN_KEY));

  function authenticated(nextToken) {
    localStorage.setItem(TOKEN_KEY, nextToken);
    setToken(nextToken);
  }

  const logout = useCallback(() => {
    localStorage.removeItem(TOKEN_KEY);
    setToken(null);
  }, []);

  return token ? (
    <Dashboard token={token} onLogout={logout} />
  ) : (
    <AuthScreen onAuthenticated={authenticated} />
  );
}

