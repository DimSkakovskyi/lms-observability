export default function Hero({ isAdmin, publishedCount, enrollmentCount, hiddenCount }) {
  return (
    <section className="hero">
      <p className="eyebrow">{isAdmin ? "Панель адміністратора" : "Освітня платформа"}</p>
      <h1>
        {isAdmin
          ? <>Керуйте знаннями<br /><em>в одному місці.</em></>
          : <>Оберіть наступну<br /><em>точку росту.</em></>}
      </h1>
      <p>
        {isAdmin
          ? "Створюйте, оновлюйте та публікуйте курси без переходу до Swagger."
          : "Практичні курси з розробки, баз даних та спостережуваності систем."}
      </p>
      <div className="hero-stats">
        <div><strong>{publishedCount}</strong><span>опубліковано</span></div>
        <div><strong>{enrollmentCount}</strong><span>моїх записів</span></div>
        <div>
          <strong>{isAdmin ? hiddenCount : 3}</strong>
          <span>{isAdmin ? "приховано" : "сигнали системи"}</span>
        </div>
      </div>
    </section>
  );
}
