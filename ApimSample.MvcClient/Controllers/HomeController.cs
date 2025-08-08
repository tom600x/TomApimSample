using System.Diagnostics;
using Microsoft.AspNetCore.Mvc;
using ApimSample.MvcClient.Models;
using ApimSample.MvcClient.Services;

namespace ApimSample.MvcClient.Controllers;

public class HomeController : Controller
{
    private readonly ILogger<HomeController> _logger;
    private readonly IWeatherService _weatherService;

    public HomeController(ILogger<HomeController> logger, IWeatherService weatherService)
    {
        _logger = logger;
        _weatherService = weatherService;
    }

    public IActionResult Index()
    {
        return View();
    }
    
    public async Task<IActionResult> DirectAuthApi()
    {
        var viewModel = await _weatherService.GetWeatherForecastAsync(ApiSource.DirectAuth);
        return View("ApiResult", viewModel);
    }

    public async Task<IActionResult> ApimAuthApi()
    {
        var viewModel = await _weatherService.GetWeatherForecastAsync(ApiSource.ApimAuth);
        return View("ApiResult", viewModel);
    }

    public IActionResult Privacy()
    {
        return View();
    }

    [ResponseCache(Duration = 0, Location = ResponseCacheLocation.None, NoStore = true)]
    public IActionResult Error()
    {
        return View(new ErrorViewModel { RequestId = Activity.Current?.Id ?? HttpContext.TraceIdentifier });
    }
}
