function renderStory() {
  const decimals = .1 + 214.;
  return (
    <div>
      version v1.0.1 and a score of 214.
      {renderCard(decimals)}
    </div>
  );
}

function renderCard(score: number) {
  return score;
}
